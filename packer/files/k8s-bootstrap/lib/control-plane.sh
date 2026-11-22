#!/usr/bin/env bash
# Control-plane bootstrap. Sourced by bin/k8s-bootstrap.
# shellcheck shell=bash
#
# Every control-plane node runs the same code. The first one to create the
# SSM parameter <prefix>/init-lock (an atomic create-if-absent) runs
# `kubeadm init`; all others, and every later replacement, join.

KUBEADM_DIR=/etc/kubernetes/kubeadm
ENCRYPTION_CONFIG=/etc/kubernetes/encryption/config.yaml

cp_main() {
  : "${KMS_KEY_ID:?}" "${SERVICE_CIDR:?}" "${IRSA_ISSUER_URL:?}" "${IRSA_BUCKET:?}"

  prepare_etcd_volume
  install -d -m 0700 /etc/kubernetes/encryption "$KUBEADM_DIR"
  install -d -m 0755 /etc/kubernetes/audit /var/log/kubernetes/audit
  install -m 0644 "$K8S_BOOTSTRAP_HOME/etc/audit-policy.yaml" /etc/kubernetes/audit/policy.yaml

  if acquire_init_lock; then
    cp_init
  else
    cp_join
  fi

  systemctl enable --now k8s-join-refresh.timer k8s-etcd-reconcile.timer k8s-etcd-backup.timer
}

# --- etcd data volume --------------------------------------------------------
prepare_etcd_volume() {
  mountpoint -q /var/lib/etcd && return 0

  local root_disk dev
  root_disk="$(lsblk -no PKNAME "$(findmnt -no SOURCE /)")"
  dev="$(lsblk -dpno NAME,TYPE | awk -v root="/dev/$root_disk" '$2 == "disk" && $1 != root {print $1; exit}')"
  [[ -n $dev ]] || die "etcd data volume not found"

  if ! blkid "$dev" >/dev/null 2>&1; then
    log "formatting $dev for etcd"
    mkfs.xfs -q -L etcd "$dev"
  fi
  install -d -m 0700 /var/lib/etcd
  grep -q 'LABEL=etcd' /etc/fstab || echo 'LABEL=etcd /var/lib/etcd xfs defaults,noatime 0 2' >>/etc/fstab
  udevadm settle
  mount /var/lib/etcd
  chmod 0700 /var/lib/etcd
}

# --- leader election via SSM ----------------------------------------------------
acquire_init_lock() {
  local err
  if err="$(aws ssm put-parameter --name "$SSM_PREFIX/init-lock" --type String \
    --value "$INSTANCE_ID" 2>&1 >/dev/null)"; then
    log "acquired init lock: this node initializes the cluster"
    return 0
  fi
  if [[ $err == *ParameterAlreadyExists* ]]; then
    log "init lock held by $(ssm_get "$SSM_PREFIX/init-lock"): joining"
    return 1
  fi
  die "could not evaluate init lock: $err"
}

write_encryption_config() {
  local key=$1
  install -m 0600 /dev/null "$ENCRYPTION_CONFIG"
  cat >"$ENCRYPTION_CONFIG" <<EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources: [secrets]
    providers:
      - secretbox:
          keys:
            - name: key1
              secret: ${key}
      - identity: {}
EOF
}

write_init_config() {
  local cert_key=$1 version
  version="$(kubeadm version -o short)"
  install -m 0600 /dev/null "$KUBEADM_DIR/init.yaml"
  cat >"$KUBEADM_DIR/init.yaml" <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
certificateKey: "${cert_key}"
localAPIEndpoint:
  advertiseAddress: "${NODE_IP}"
  bindPort: 6443
nodeRegistration:
  name: "${NODE_NAME}"
  criSocket: unix:///run/containerd/containerd.sock
$(kubelet_args_yaml)
skipPhases:
  - addon/kube-proxy # Cilium replaces kube-proxy
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
clusterName: "${CLUSTER_NAME}"
kubernetesVersion: "${version}"
controlPlaneEndpoint: "${API_ENDPOINT}:6443"
networking:
  serviceSubnet: "${SERVICE_CIDR}"
  dnsDomain: cluster.local
apiServer:
  certSANs:
    - "${API_ENDPOINT}"
    - "${API_NLB_DNS}"
  extraArgs:
    - name: service-account-issuer
      value: "${IRSA_ISSUER_URL}"
    - name: service-account-jwks-uri
      value: "${IRSA_ISSUER_URL}/openid/v1/jwks"
    - name: encryption-provider-config
      value: ${ENCRYPTION_CONFIG}
    - name: audit-policy-file
      value: /etc/kubernetes/audit/policy.yaml
    - name: audit-log-path
      value: /var/log/kubernetes/audit/audit.log
    - name: audit-log-maxage
      value: "30"
    - name: audit-log-maxbackup
      value: "10"
    - name: audit-log-maxsize
      value: "100"
    - name: profiling
      value: "false"
    - name: tls-min-version
      value: VersionTLS12
  extraVolumes:
    - name: encryption-config
      hostPath: /etc/kubernetes/encryption
      mountPath: /etc/kubernetes/encryption
      readOnly: true
      pathType: DirectoryOrCreate
    - name: audit-policy
      hostPath: /etc/kubernetes/audit
      mountPath: /etc/kubernetes/audit
      readOnly: true
      pathType: DirectoryOrCreate
    - name: audit-logs
      hostPath: /var/log/kubernetes/audit
      mountPath: /var/log/kubernetes/audit
      readOnly: false
      pathType: DirectoryOrCreate
controllerManager:
  extraArgs:
    - name: cloud-provider
      value: external
    - name: profiling
      value: "false"
    - name: terminated-pod-gc-threshold
      value: "1000"
scheduler:
  extraArgs:
    - name: profiling
      value: "false"
etcd:
  local:
    dataDir: /var/lib/etcd
    extraArgs:
      - name: quota-backend-bytes
        value: "8589934592"
      - name: auto-compaction-retention
        value: "8"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
readOnlyPort: 0
protectKernelDefaults: true
rotateCertificates: true
serverTLSBootstrap: true # serving certs need approval: deploy kubelet-csr-approver via GitOps
tlsMinVersion: VersionTLS12
eventRecordQPS: 5
shutdownGracePeriod: 60s
shutdownGracePeriodCriticalPods: 20s
EOF
}

write_cp_join_config() {
  local token=$1 ca_hash=$2 cert_key=$3
  install -m 0600 /dev/null "$KUBEADM_DIR/join.yaml"
  cat >"$KUBEADM_DIR/join.yaml" <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: JoinConfiguration
discovery:
  bootstrapToken:
    apiServerEndpoint: "${API_ENDPOINT}:6443"
    token: "${token}"
    caCertHashes: ["${ca_hash}"]
nodeRegistration:
  name: "${NODE_NAME}"
  criSocket: unix:///run/containerd/containerd.sock
$(kubelet_args_yaml)
controlPlane:
  localAPIEndpoint:
    advertiseAddress: "${NODE_IP}"
    bindPort: 6443
  certificateKey: "${cert_key}"
EOF
}

# --- init ------------------------------------------------------------------------
cp_init() {
  local cert_key enc_key
  cert_key="$(kubeadm certs certificate-key)"
  enc_key="$(head -c 32 /dev/urandom | base64)"

  # Persist secrets first so peers can read them as soon as they exist.
  ssm_put_secure "$SSM_PREFIX/secrets/encryption-key" "$enc_key"
  ssm_put_secure "$SSM_PREFIX/join/certificate-key" "$cert_key"

  write_encryption_config "$enc_key"
  write_init_config "$cert_key"

  log "kubeadm init"
  kubeadm init --config "$KUBEADM_DIR/init.yaml" --upload-certs

  export KUBECONFIG=/etc/kubernetes/admin.conf
  retry 30 10 kubectl get --raw /readyz >/dev/null

  publish_join_material
  publish_irsa_discovery
  # Break-glass kubeconfig (kubeadm:cluster-admins). Advanced tier: > 4 KB.
  ssm_put_secure "$SSM_PREFIX/secrets/admin-kubeconfig" "$(cat /etc/kubernetes/admin.conf)" Advanced

  # shellcheck source=addons.sh
  source "$K8S_BOOTSTRAP_HOME/lib/addons.sh"
  install_addons

  ssm_put_string "$SSM_PREFIX/initialized" "$(date -u +%FT%TZ) by $INSTANCE_ID"
  log "cluster initialized"
}

# --- join ------------------------------------------------------------------------
cp_join() {
  wait_for_initialized

  local cert_key token ca_hash attempt
  write_encryption_config "$(ssm_get "$SSM_PREFIX/secrets/encryption-key")"
  cert_key="$(ssm_get "$SSM_PREFIX/join/certificate-key")"

  # Retries cover: an expired token being refreshed, the uploaded certs secret
  # having expired (refreshed every 30 min), and etcd refusing a new member
  # while a dead one is still registered (the reconciler removes it).
  for attempt in $(seq 1 20); do
    token="$(ssm_get "$SSM_PREFIX/join/token")"
    ca_hash="$(ssm_get "$SSM_PREFIX/join/ca-cert-hash")"
    write_cp_join_config "$token" "$ca_hash" "$cert_key"

    if kubeadm join --config "$KUBEADM_DIR/join.yaml"; then
      log "joined as control-plane node"
      return 0
    fi
    log "control-plane join attempt $attempt failed; resetting and retrying"
    kubeadm reset --force --cleanup-tmp-dir || true
    sleep 30
  done
  die "control-plane join failed after 20 attempts"
}
