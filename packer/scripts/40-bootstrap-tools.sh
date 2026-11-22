#!/usr/bin/env bash
# Helm (used once, by the first control-plane node) and the k8s-bootstrap
# scripts + systemd units.
set -euo pipefail
: "${HELM_VERSION:?}"

tmp="$(mktemp -d)"
curl -fsSLo "$tmp/helm.tgz" "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz"
curl -fsSLo "$tmp/helm.tgz.sha256sum" "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz.sha256sum"
(cd "$tmp" && sed "s#helm-v${HELM_VERSION}-linux-amd64.tar.gz#helm.tgz#" helm.tgz.sha256sum | sha256sum -c -)
tar -xzf "$tmp/helm.tgz" -C "$tmp"
install -m 0755 "$tmp/linux-amd64/helm" /usr/local/bin/helm
rm -rf "$tmp"
helm version --short

# Bootstrap scripts (uploaded to /tmp by the file provisioner)
install -d -m 0755 /opt/k8s-bootstrap/bin /opt/k8s-bootstrap/lib /opt/k8s-bootstrap/etc
install -m 0755 /tmp/k8s-bootstrap/bin/* /opt/k8s-bootstrap/bin/
install -m 0644 /tmp/k8s-bootstrap/lib/* /opt/k8s-bootstrap/lib/
install -m 0644 /tmp/k8s-bootstrap/etc/* /opt/k8s-bootstrap/etc/
install -m 0644 /tmp/k8s-bootstrap/systemd/* /etc/systemd/system/
install -d -m 0700 /etc/k8s-bootstrap
rm -rf /tmp/k8s-bootstrap

systemctl daemon-reload
# k8s-bootstrap.service is started by cloud-init runcmd (only when user data
# provides cluster.env); the timers are enabled by the control-plane bootstrap.
