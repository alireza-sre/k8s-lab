#!/usr/bin/env bash
# containerd + kubelet/kubeadm/kubectl. Installs the newest patch release of
# $KUBERNETES_MINOR and pins it, then pre-pulls control-plane images so nodes
# boot without depending on registry.k8s.io.
set -euo pipefail
: "${KUBERNETES_MINOR:?}"

# --- containerd (Ubuntu package; security fixes arrive with each rebuild) ----
apt-get -y install containerd
install -d /etc/containerd
containerd config default >/etc/containerd/config.toml

# --- Kubernetes packages from pkgs.k8s.io --------------------------------------
install -d -m 0755 /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_MINOR}/deb/Release.key" |
  gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_MINOR}/deb/ /" \
  >/etc/apt/sources.list.d/kubernetes.list
apt-get update

pkg_version="$(apt-cache madison kubeadm | awk '{print $3}' | sort -V | tail -n1)"
[[ -n $pkg_version ]] || {
  echo "no kubeadm package for ${KUBERNETES_MINOR}" >&2
  exit 1
}
apt-get -y install "kubelet=${pkg_version}" "kubeadm=${pkg_version}" "kubectl=${pkg_version}"
apt-mark hold kubelet kubeadm kubectl containerd

KUBE_VERSION="$(kubeadm version -o short)"
echo "Installed Kubernetes ${KUBE_VERSION}"
echo "${KUBE_VERSION}" >/etc/k8s-version

# --- containerd config: systemd cgroups + the pause image kubeadm expects -----------
pause_image="$(kubeadm config images list --kubernetes-version "${KUBE_VERSION}" | grep /pause:)"
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
# containerd 1.7 (sandbox_image) and 2.x (sandbox) key names
sed -i -E "s#^(\s*sandbox_image\s*=\s*).*#\1\"${pause_image}\"#; s#^(\s*sandbox\s*=\s*)\"registry.k8s.io/pause.*#\1\"${pause_image}\"#" /etc/containerd/config.toml
grep -q 'SystemdCgroup = true' /etc/containerd/config.toml || {
  echo "failed to enable SystemdCgroup in containerd config" >&2
  exit 1
}
systemctl restart containerd
systemctl enable containerd kubelet

cat >/etc/crictl.yaml <<'EOF'
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 10
EOF

# --- pre-pull control-plane images ----------------------------------------------------
kubeadm config images pull --kubernetes-version "${KUBE_VERSION}"
