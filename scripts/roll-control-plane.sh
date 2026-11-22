#!/usr/bin/env bash
# Replace control-plane nodes ONE AT A TIME (new AMI, new launch template).
#
# For each of the three ASGs: terminate its instance (the lifecycle hook lets
# node-termination-handler drain it), wait for the replacement to join, then
# wait until every control-plane node is Ready and all etcd members are
# healthy before touching the next one.
#
#   ./scripts/get-kubeconfig.sh lab tunnel   # in another terminal
#   KUBECONFIG=~/.kube/kube-ec2-lab.conf ./scripts/roll-control-plane.sh lab
set -Eeuo pipefail

ENV_NAME="${1:-lab}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="$ROOT/live/$ENV_NAME/common.tfvars"
val() { awk -F'"' -v k="$1" '$1 ~ "^"k" *= *" {print $2}' "$COMMON"; }
AWS_DEFAULT_REGION="$(val region)"
export AWS_DEFAULT_REGION
PREFIX="/$(val project)/$(val environment)"

log() { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

command -v kubectl >/dev/null || die "kubectl required (and a working KUBECONFIG)"
kubectl get --raw /readyz >/dev/null || die "API not reachable; is the tunnel running?"

mapfile -t ASGS < <(aws ssm get-parameter --name "$PREFIX/30-cluster/control_plane_asg_names" \
  --query Parameter.Value --output text | jq -r '.[]')

etcd_healthy() {
  local pod
  pod="$(kubectl -n kube-system get pods -l component=etcd -o jsonpath='{.items[0].metadata.name}')"
  kubectl -n kube-system exec "$pod" -- etcdctl \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
    --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
    endpoint health --cluster >/dev/null 2>&1
}

cp_ready_count() {
  kubectl get nodes -l node-role.kubernetes.io/control-plane \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | grep -c True || true
}

wait_for() {
  local what=$1 timeout=$2
  shift 2
  local start=$SECONDS
  until "$@"; do
    ((SECONDS - start > timeout)) && die "timed out waiting for $what"
    sleep 15
  done
}

three_ready() { [[ $(cp_ready_count) -eq 3 ]]; }

log "pre-flight: 3 Ready control-plane nodes and healthy etcd"
three_ready || die "not all control-plane nodes are Ready"
etcd_healthy || die "etcd is not healthy"

for asg in "${ASGS[@]}"; do
  old="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$asg" \
    --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)"
  log "$asg: replacing $old"
  read -r -p "Proceed? [y/N] " ok
  [[ $ok == [yY] ]] || die "aborted"

  aws autoscaling terminate-instance-in-auto-scaling-group \
    --instance-id "$old" --no-should-decrement-desired-capacity >/dev/null

  log "waiting for $old to terminate"
  aws ec2 wait instance-terminated --instance-ids "$old"

  log "waiting for the replacement to join (etcd reconciler removes the old member)"
  wait_for "3 Ready control-plane nodes" 1800 three_ready
  wait_for "healthy etcd" 600 etcd_healthy
  log "$asg done"
done

log "control plane rolled"
