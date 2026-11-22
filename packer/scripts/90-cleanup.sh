#!/usr/bin/env bash
# Make the image generic: no host identity, no build leftovers, no SSH.
set -euo pipefail

apt-get -y autoremove --purge
apt-get clean
rm -rf /var/lib/apt/lists/*

# Fresh identity on every instance.
cloud-init clean --logs --seed
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
rm -f /etc/ssh/ssh_host_*

# Nodes are reached through SSM Session Manager only. (The Packer session
# itself survives: the change applies from the next boot.)
systemctl disable ssh.service ssh.socket 2>/dev/null || true

rm -rf /tmp/* /var/tmp/* /root/.bash_history /home/ubuntu/.bash_history
find /var/log -type f -exec truncate -s 0 {} +
sync
