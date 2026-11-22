#!/usr/bin/env bash
# Shared helpers for the k8s-bootstrap scripts. Sourced, never executed.
# shellcheck shell=bash

ENV_FILE=/etc/k8s-bootstrap/cluster.env
export STATE_DIR=/var/lib/k8s-bootstrap
export K8S_BOOTSTRAP_HOME=/opt/k8s-bootstrap

log() { printf '[k8s-bootstrap] %s %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
die() {
  log "FATAL: $*"
  exit 1
}

load_env() {
  [[ -r $ENV_FILE ]] || die "missing $ENV_FILE (user data not applied?)"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
  : "${CLUSTER_NAME:?}" "${AWS_REGION:?}" "${SSM_PREFIX:?}" "${API_ENDPOINT:?}" "${ROLE:?}"
  export AWS_DEFAULT_REGION="$AWS_REGION"
  export AWS_RETRY_MODE=adaptive AWS_MAX_ATTEMPTS=10
}

# IMDSv2 only.
imds() {
  local token
  token="$(curl -fsS -X PUT http://169.254.169.254/latest/api/token \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')"
  curl -fsS -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/meta-data/$1"
}

discover_node() {
  NODE_IP="$(imds local-ipv4)"
  NODE_NAME="$(imds local-hostname)" # EC2 private DNS name; what the AWS CCM expects
  INSTANCE_ID="$(imds instance-id)"
  export NODE_IP NODE_NAME INSTANCE_ID
}

# retry <attempts> <delay-seconds> <command...>
retry() {
  local attempts=$1 delay=$2 n=1
  shift 2
  until "$@"; do
    ((n >= attempts)) && return 1
    log "retry $n/$attempts in ${delay}s: $*"
    sleep "$delay"
    ((n++))
  done
}

# --- SSM ---------------------------------------------------------------------
ssm_get() {
  aws ssm get-parameter --name "$1" --with-decryption --query Parameter.Value --output text
}

ssm_exists() {
  aws ssm get-parameter --name "$1" >/dev/null 2>&1
}

ssm_put_string() {
  aws ssm put-parameter --name "$1" --type String --value "$2" --overwrite >/dev/null
}

# ssm_put_secure <name> <value> [tier]
ssm_put_secure() {
  aws ssm put-parameter --name "$1" --type SecureString --key-id "$KMS_KEY_ID" \
    --value "$2" --tier "${3:-Standard}" --overwrite >/dev/null
}

wait_for_initialized() {
  local i
  for i in $(seq 1 90); do
    if ssm_exists "$SSM_PREFIX/initialized"; then
      log "cluster is initialized"
      return 0
    fi
    log "waiting for cluster initialization ($i/90)"
    sleep 20
  done
  die "cluster never became initialized (check the node holding $SSM_PREFIX/init-lock)"
}

ca_cert_hash() {
  openssl x509 -pubkey -noout -in /etc/kubernetes/pki/ca.crt |
    openssl pkey -pubin -outform der |
    openssl dgst -sha256 -hex | awk '{print "sha256:" $NF}'
}

# Fresh bootstrap token + CA hash for joining nodes. Tokens live 2h; the
# refresh timer runs every 30 min, so a valid token is always published.
publish_join_material() {
  local token
  token="$(kubeadm token create --ttl 2h --description "k8s-bootstrap $(date -u +%FT%TZ)")"
  ssm_put_secure "$SSM_PREFIX/join/token" "$token"
  ssm_put_string "$SSM_PREFIX/join/ca-cert-hash" "$(ca_cert_hash)"
}

# AWS STS fetches these to validate IRSA tokens (see modules/irsa-issuer).
publish_irsa_discovery() {
  local tmp
  tmp="$(mktemp -d)"
  kubectl get --raw /.well-known/openid-configuration >"$tmp/openid-configuration"
  kubectl get --raw /openid/v1/jwks >"$tmp/jwks"
  aws s3 cp "$tmp/openid-configuration" "s3://$IRSA_BUCKET/.well-known/openid-configuration" \
    --content-type application/json --only-show-errors
  aws s3 cp "$tmp/jwks" "s3://$IRSA_BUCKET/openid/v1/jwks" \
    --content-type application/json --only-show-errors
  rm -rf "$tmp"
}

kubelet_args_yaml() {
  # Renders nodeRegistration.kubeletExtraArgs (kubeadm v1beta4 list form).
  cat <<EOF
  kubeletExtraArgs:
    - name: cloud-provider
      value: external
    - name: node-ip
      value: "$NODE_IP"
EOF
  if [[ -n ${NODE_LABELS:-} ]]; then
    printf '    - name: node-labels\n      value: "%s"\n' "$NODE_LABELS"
  fi
}

taints_yaml() {
  local t key rest value effect
  local -a list=()
  [[ -n ${NODE_TAINTS:-} ]] && IFS=',' read -r -a list <<<"$NODE_TAINTS"
  if ((${#list[@]} == 0)); then
    echo "  taints: []"
    return
  fi
  echo "  taints:"
  for t in "${list[@]}"; do
    key="${t%%=*}"
    rest="${t#*=}"
    value="${rest%%:*}"
    effect="${rest##*:}"
    printf '    - key: "%s"\n      value: "%s"\n      effect: %s\n' "$key" "$value" "$effect"
  done
}
