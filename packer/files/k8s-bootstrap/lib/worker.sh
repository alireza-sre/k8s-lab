#!/usr/bin/env bash
# Worker bootstrap. Sourced by bin/k8s-bootstrap.
# shellcheck shell=bash

worker_main() {
  wait_for_initialized

  local token ca_hash attempt
  install -d -m 0700 /etc/kubernetes/kubeadm

  for attempt in $(seq 1 20); do
    token="$(ssm_get "$SSM_PREFIX/join/token")"
    ca_hash="$(ssm_get "$SSM_PREFIX/join/ca-cert-hash")"

    install -m 0600 /dev/null /etc/kubernetes/kubeadm/join.yaml
    cat >/etc/kubernetes/kubeadm/join.yaml <<EOF
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
$(taints_yaml)
EOF

    if kubeadm join --config /etc/kubernetes/kubeadm/join.yaml; then
      log "joined as worker (pool=${NODE_POOL:-none})"
      return 0
    fi
    log "worker join attempt $attempt failed; resetting and retrying"
    kubeadm reset --force --cleanup-tmp-dir || true
    sleep 20
  done
  die "worker join failed after 20 attempts"
}
