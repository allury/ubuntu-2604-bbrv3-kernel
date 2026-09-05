#!/usr/bin/env bash
set -euo pipefail

expected_release="${1:-}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$script_dir/bbrv3.sysctl.conf" ]]; then
  config_file="$script_dir/bbrv3.sysctl.conf"
else
  config_file="$script_dir/../config/bbrv3.sysctl.conf"
fi

if [[ "$(id -u)" -ne 0 ]]; then
  printf 'Run this script as root (for example: sudo %s [expected-kernel-release]).\n' "$0" >&2
  exit 1
fi

running_release="$(uname -r)"
[[ -z "$expected_release" || "$running_release" == "$expected_release" ]] || {
  printf 'ERROR: Running %s, but expected %s. Reboot into the custom kernel first.\n' \
    "$running_release" "$expected_release" >&2
  exit 1
}
[[ -f "$config_file" ]] || {
  printf 'ERROR: Cannot find bbrv3.sysctl.conf next to this helper or in config/.\n' >&2
  exit 1
}

if command -v mokutil >/dev/null && mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
  printf 'NOTE: Secure Boot is enabled; this only works if the booted custom kernel is signed and trusted.\n' >&2
fi

modprobe tcp_bbr
module_path="$(modinfo -n tcp_bbr)"
module_version="$(modinfo -F version tcp_bbr || true)"
module_vermagic="$(modinfo -F vermagic tcp_bbr || true)"

[[ -r "$module_path" ]] || { printf 'ERROR: tcp_bbr has no readable module file.\n' >&2; exit 1; }
[[ "$module_version" == "3" ]] || {
  printf 'ERROR: tcp_bbr module version is %s, expected BBRv3 version 3.\n' "${module_version:-missing}" >&2
  exit 1
}
[[ "$module_vermagic" == "$running_release"* ]] || {
  printf 'ERROR: tcp_bbr vermagic does not match the running kernel: %s\n' "${module_vermagic:-missing}" >&2
  exit 1
}

install -D -m 0644 "$config_file" /etc/sysctl.d/99-bbrv3.conf
sysctl --system

grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control ||
  { printf 'ERROR: bbr is not available in the running kernel.\n' >&2; exit 1; }
[[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == "bbr" ]] ||
  { printf 'ERROR: tcp_congestion_control was not set to bbr.\n' >&2; exit 1; }
[[ "$(sysctl -n net.core.default_qdisc)" == "fq" ]] ||
  { printf 'ERROR: default_qdisc was not set to fq.\n' >&2; exit 1; }

printf 'BBRv3 enabled on %s: selector=%s, module-version=%s\n' \
  "$running_release" "$(sysctl -n net.ipv4.tcp_congestion_control)" "$module_version"
