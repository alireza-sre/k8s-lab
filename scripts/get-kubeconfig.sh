#!/usr/bin/env bash
# Break-glass kubectl access to the private API endpoint through an SSM port
# forward (no bastion, no public endpoint, no SSH).
#
#   ./scripts/get-kubeconfig.sh lab          # writes ~/.kube/kube-ec2-lab.conf, then
#   ./scripts/get-kubeconfig.sh lab tunnel   # keep running in another terminal
#   KUBECONFIG=~/.kube/kube-ec2-lab.conf kubectl get nodes
#
# Needs: aws cli v2 + session-manager-plugin, credentials allowed to read the
# admin kubeconfig parameter (deployer role or admin). This is a cluster-admin
# credential: day-to-day access should use OIDC (configured via GitOps).
set -Eeuo pipefail

ENV_NAME="${1:-lab}"
MODE="${2:-config}"
LOCAL_PORT="${LOCAL_PORT:-16443}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="$ROOT/live/$ENV_NAME/common.tfvars"

val() { awk -F'"' -v k="$1" '$1 ~ "^"k" *= *" {print $2}' "$COMMON"; }
PROJECT="$(val project)"
ENVIRONMENT="$(val environment)"
AWS_DEFAULT_REGION="$(val region)"
export AWS_DEFAULT_REGION
PREFIX="/$PROJECT/$ENVIRONMENT"

param() { aws ssm get-parameter --name "$1" --with-decryption --query Parameter.Value --output text; }

RUNTIME_PREFIX="$(param "$PREFIX/30-cluster/runtime_ssm_prefix")"
API_ENDPOINT="$(param "$PREFIX/30-cluster/api_endpoint")"
CLUSTER="$(param "$PREFIX/30-cluster/cluster_name")"
OUT="$HOME/.kube/$CLUSTER.conf"

if [[ $MODE == tunnel ]]; then
  # Any running control-plane instance can relay to the NLB.
  TARGET="$(aws ec2 describe-instances \
    --filters "Name=tag:kubernetes.io/cluster/$CLUSTER,Values=owned" \
    "Name=tag:k8s.io/node-pool,Values=control-plane" \
    "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text)"
  [[ $TARGET != None ]] || { echo "no running control-plane instance" >&2; exit 1; }
  echo "Forwarding localhost:$LOCAL_PORT -> $API_ENDPOINT:6443 via $TARGET (Ctrl-C to stop)"
  exec aws ssm start-session --target "$TARGET" \
    --document-name AWS-StartPortForwardingSessionToRemoteHost \
    --parameters "host=$API_ENDPOINT,portNumber=6443,localPortNumber=$LOCAL_PORT"
fi

mkdir -p "$HOME/.kube"
umask 077
param "$RUNTIME_PREFIX/secrets/admin-kubeconfig" >"$OUT"
# Talk to the tunnel but verify the API certificate against its real name.
KUBECONFIG="$OUT" kubectl config set-cluster "$CLUSTER" \
  --server="https://127.0.0.1:$LOCAL_PORT" --tls-server-name="$API_ENDPOINT" >/dev/null
echo "Wrote $OUT. Start the tunnel: $0 $ENV_NAME tunnel"
