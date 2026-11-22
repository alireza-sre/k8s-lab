#!/usr/bin/env bash
# Minimal in-cluster bootstrap, run once by the node that ran `kubeadm init`.
# shellcheck shell=bash
#
# Only what Argo CD itself needs to run is installed here:
#   1. Cilium        - nodes stay NotReady without a CNI
#   2. AWS CCM       - removes the node.cloudprovider.kubernetes.io/uninitialized
#                      taint so anything can schedule
#   3. Argo CD       - platform instance
#   4. root App      - points Argo CD at gitops/clusters/<env>
#
# Argo CD then adopts Cilium, the CCM and itself (same release names and
# namespaces, values kept in Git), so these versions only matter for day 0.

ARGOCD_NAMESPACE=argocd-platform
RENDER_DIR=/etc/k8s-bootstrap/rendered

install_addons() {
  export KUBECONFIG=/etc/kubernetes/admin.conf
  install -d -m 0700 "$RENDER_DIR"

  install_cilium
  install_ccm
  install_argocd
}

install_cilium() {
  cat >"$RENDER_DIR/cilium.yaml" <<EOF
k8sServiceHost: ${API_ENDPOINT}
k8sServicePort: 6443
kubeProxyReplacement: true

# ENI IPAM: pods get real VPC IPs from the node's subnet, so NLBs can target
# pods directly (IP target groups) and VPC flow logs show pod IPs.
ipam:
  mode: eni
eni:
  enabled: true
  awsEnablePrefixDelegation: true
  awsReleaseExcessIPs: true
  updateEC2AdapterLimitViaAPI: true
routingMode: native
ipv4NativeRoutingCIDR: ${VPC_CIDR}
egressMasqueradeInterfaces: ens+
endpointRoutes:
  enabled: true

operator:
  replicas: 2
  # Runs with the control-plane instance profile (ENI permissions).
  nodeSelector:
    node-role.kubernetes.io/control-plane: ""
  tolerations:
    - operator: Exists

hubble:
  enabled: true
  relay:
    enabled: true
gatewayAPI:
  enabled: false # Envoy Gateway is the Gateway API implementation
EOF

  log "installing cilium ${CILIUM_VERSION}"
  retry 5 15 helm upgrade --install cilium cilium \
    --repo https://helm.cilium.io --version "$CILIUM_VERSION" \
    --namespace kube-system --values "$RENDER_DIR/cilium.yaml"
  kubectl -n kube-system rollout status ds/cilium --timeout=10m
}

install_ccm() {
  cat >"$RENDER_DIR/ccm.yaml" <<EOF
args:
  - --v=2
  - --cloud-provider=aws
  - --configure-cloud-routes=false
  # LoadBalancers are owned by Terraform (NLBs) + aws-load-balancer-controller
  # (TargetGroupBinding), never by the CCM.
  - --controllers=*,-service,-route
nodeSelector:
  node-role.kubernetes.io/control-plane: ""
EOF

  log "installing aws-cloud-controller-manager chart ${CCM_CHART_VERSION}"
  retry 5 15 helm upgrade --install aws-cloud-controller-manager aws-cloud-controller-manager \
    --repo https://kubernetes.github.io/cloud-provider-aws --version "$CCM_CHART_VERSION" \
    --namespace kube-system --values "$RENDER_DIR/ccm.yaml" --wait --timeout 10m
}

install_argocd() {
  kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  cat >"$RENDER_DIR/argocd.yaml" <<EOF
global:
  # Platform components run on the dedicated system pool.
  nodeSelector:
    ${NODE_LABEL_DOMAIN}/pool: system
  tolerations:
    - key: ${NODE_LABEL_DOMAIN}/pool
      operator: Equal
      value: system
      effect: NoSchedule
configs:
  params:
    server.insecure: false
  cm:
    admin.enabled: true # disable once SSO (OIDC) is configured via GitOps
    exec.enabled: false
dex:
  enabled: false
controller:
  replicas: 1
server:
  replicas: 2
repoServer:
  replicas: 2
applicationSet:
  replicas: 2
EOF

  log "installing argo-cd chart ${ARGOCD_CHART_VERSION}"
  # No --wait: Argo CD runs on workers, which may still be joining.
  retry 5 15 helm upgrade --install argocd argo-cd \
    --repo https://argoproj.github.io/argo-helm --version "$ARGOCD_CHART_VERSION" \
    --namespace "$ARGOCD_NAMESPACE" --values "$RENDER_DIR/argocd.yaml"

  configure_repo_credentials
  apply_root_application
}

configure_repo_credentials() {
  [[ -n ${GITOPS_REPO_SSH_KEY_PARAM:-} ]] || return 0
  log "creating Argo CD repository secret from $GITOPS_REPO_SSH_KEY_PARAM"
  local key
  key="$(ssm_get "$GITOPS_REPO_SSH_KEY_PARAM")"
  kubectl -n "$ARGOCD_NAMESPACE" create secret generic gitops-repo \
    --from-literal=type=git \
    --from-literal=url="$GITOPS_REPO_URL" \
    --from-literal=sshPrivateKey="$key" \
    --dry-run=client -o yaml |
    kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml |
    kubectl apply -f -
}

apply_root_application() {
  [[ -n ${GITOPS_REPO_URL:-} ]] || {
    log "GITOPS_REPO_URL empty: skipping root application"
    return 0
  }
  cat >"$RENDER_DIR/root-app.yaml" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: ${ARGOCD_NAMESPACE}
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${GITOPS_REPO_URL}
    targetRevision: ${GITOPS_REVISION:-main}
    path: ${GITOPS_PATH}
  destination:
    server: https://kubernetes.default.svc
    namespace: ${ARGOCD_NAMESPACE}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
EOF
  # CRDs from the chart may take a moment to be established.
  retry 30 10 kubectl apply -f "$RENDER_DIR/root-app.yaml"
}
