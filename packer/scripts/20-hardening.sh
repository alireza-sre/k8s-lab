#!/usr/bin/env bash
# Host hardening and kernel settings required by Kubernetes.
set -euo pipefail

# --- kernel modules / sysctls -------------------------------------------------
cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat >/etc/sysctl.d/90-kubernetes.conf <<'EOF'
# Required by kubelet protectKernelDefaults=true (it refuses to start otherwise)
vm.overcommit_memory = 1
vm.panic_on_oom = 0
kernel.panic = 10
kernel.panic_on_oops = 1
kernel.keys.root_maxkeys = 1000000
kernel.keys.root_maxbytes = 25000000

# Pod networking
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
# Cilium ENI mode uses source-based routing across multiple ENIs
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0

# Hardening
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.unprivileged_bpf_disabled = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.tcp_syncookies = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.suid_dumpable = 0

# Many pods => many inotify watches
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 8192
EOF
sysctl --system >/dev/null

# --- swap must be off (kubelet default) ----------------------------------------
swapoff -a
sed -i '/\sswap\s/s/^/#/' /etc/fstab

# --- SSH: no passwords, no root. Disabled entirely in 90-cleanup.sh;
#     access is through SSM Session Manager only. -----------------------------------
cat >/etc/ssh/sshd_config.d/90-hardening.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
X11Forwarding no
AllowAgentForwarding no
MaxAuthTries 3
EOF

# --- no in-place upgrades: nodes are replaced, never patched -------------------------
systemctl disable --now unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
apt-get -y purge unattended-upgrades || true

# --- audit essentials ------------------------------------------------------------------
cat >/etc/audit/rules.d/90-kubernetes.rules <<'EOF'
-w /etc/kubernetes/ -p wa -k kubernetes
-w /var/lib/kubelet/ -p wa -k kubelet
-w /etc/containerd/ -p wa -k containerd
-w /etc/sudoers -p wa -k scope
-w /etc/sudoers.d/ -p wa -k scope
-w /usr/bin/kubeadm -p x -k kubeadm
EOF
systemctl enable auditd

# --- journald: bounded size ---------------------------------------------------------------
mkdir -p /etc/systemd/journald.conf.d
cat >/etc/systemd/journald.conf.d/90-size.conf <<'EOF'
[Journal]
SystemMaxUse=1G
EOF
