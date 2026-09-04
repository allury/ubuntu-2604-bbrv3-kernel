#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  printf 'Run this script as root (for example: sudo %s).\n' "$0" >&2
  exit 1
fi

if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
  printf 'ERROR: Secure Boot is enabled. Do not enable an unsigned custom kernel until it is signed and trusted.\n' >&2
  exit 1
fi

modprobe tcp_bbr
install -D -m 0644 "$(dirname "$0")/../config/bbrv3.sysctl.conf" /etc/sysctl.d/99-bbrv3.conf
sysctl --system

grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control ||
  { printf 'ERROR: bbr is not available in the running kernel.\n' >&2; exit 1; }

printf 'BBRv3 enabled: %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control)"
modinfo -F version tcp_bbr || true
