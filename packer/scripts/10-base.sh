#!/usr/bin/env bash
# Base OS: latest packages, tooling the bootstrap scripts need, AWS CLI v2.
set -euo pipefail

# cloud-init may still be running apt on first boot.
cloud-init status --wait >/dev/null || true

apt-get update
apt-get -y -o Dpkg::Options::=--force-confold dist-upgrade
apt-get -y install --no-install-recommends \
  apt-transport-https ca-certificates curl gnupg jq unzip \
  conntrack socat ethtool ebtables ipset \
  nvme-cli xfsprogs \
  chrony auditd \
  openssl

# AWS CLI v2 from the AWS-published snap (signed by the Snap Store; avoids
# hand-maintaining the CLI's PGP key here). systemd units don't have /snap/bin
# on PATH, so link it into /usr/local/bin.
snap install aws-cli --classic
ln -sf /snap/bin/aws /usr/local/bin/aws
/usr/local/bin/aws --version

# Amazon Time Sync Service (link-local; no internet dependency).
if ! grep -q 169.254.169.123 /etc/chrony/chrony.conf; then
  sed -i '1i server 169.254.169.123 prefer iburst minpoll 4 maxpoll 4' /etc/chrony/chrony.conf
fi
systemctl enable chrony
