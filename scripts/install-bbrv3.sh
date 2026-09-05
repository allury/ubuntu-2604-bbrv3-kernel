#!/usr/bin/env bash
# Run from an extracted, reviewed release directory. Never selects latest prerelease.
set -euo pipefail
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $EUID == 0 ]] || die 'Run with sudo.'
mode="${1:-install}"
state=/var/lib/bbrv3-installer
if [[ "$mode" == test ]]; then
  expected="$(cat "$state/expected-release")"
  [[ "$(uname -r)" == "$expected" ]] || die "Booted $(uname -r), expected $expected. Select the target kernel in GRUB."
  "$state/enable-bbrv3.sh" "$expected"
  # Exercise a real TCP connection with BBR, without sending external traffic.
  python3 - <<'PY'
import socket
with socket.socket() as listener, socket.socket() as client:
    listener.bind(('127.0.0.1', 0))
    listener.listen(1)
    client.settimeout(5)
    client.setsockopt(socket.IPPROTO_TCP, socket.TCP_CONGESTION, b'bbr')
    client.connect(listener.getsockname())
    with listener.accept()[0] as peer:
        peer.settimeout(5)
        client.sendall(b'bbrv3-smoke-test')
        data = b''
        while len(data) < 16:
            chunk = peer.recv(16 - len(data))
            if not chunk:
                raise RuntimeError('Unexpected TCP EOF')
            data += chunk
        assert data == b'bbrv3-smoke-test'
        assert client.getsockopt(socket.IPPROTO_TCP, socket.TCP_CONGESTION, 16).rstrip(b'\0') == b'bbr'
print('PASS: local TCP transfer using bbr (not a throughput or WAN test).')
PY
  printf 'PASS: booted %s and loaded BBRv3; review journalctl -k -b for kernel warnings.\n' "$expected"
  exit 0
fi
[[ "$mode" == install ]] || die 'Usage: install-bbrv3.sh install [--reboot] | test'
[[ $# -le 2 && ( -z "${2:-}" || "${2:-}" == --reboot ) ]] || die 'Unknown option.'
# shellcheck source=/dev/null
source /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_ID" == 26.04 ]] || die 'Requires Ubuntu 26.04.'
[[ "$(dpkg --print-architecture)" == amd64 ]] || die 'Requires amd64.'
for tool in systemctl systemd-detect-virt python3 mokutil apt-get dpkg-deb update-grub sha256sum; do
  command -v "$tool" >/dev/null || die "Missing prerequisite: $tool"
done
if systemd-detect-virt --container --quiet; then die 'Containers cannot replace the host kernel.'; fi
[[ -d /run/systemd/system && -f /boot/grub/grub.cfg ]] || die 'Requires systemd and GRUB.'
if [[ -d /sys/firmware/efi ]]; then
  sb="$(mokutil --sb-state)" || die 'Cannot determine Secure Boot state.'
  grep -qi 'SecureBoot disabled' <<<"$sb" || die 'Unsigned release requires Secure Boot disabled; signed installations need a separate procedure.'
fi
for file in SHA256SUMS enable-bbrv3.sh bbrv3.sysctl.conf; do
  [[ -f "$file" ]] || die "Run in the release directory; missing $file"
done
sha256sum --check --strict SHA256SUMS
shopt -s nullglob
packages=(./*.deb)
(( ${#packages[@]} > 0 )) || die 'No packages.'
expected=''
version=''
for package in "${packages[@]}"; do
  name="$(dpkg-deb -f "$package" Package)"
  current_version="$(dpkg-deb -f "$package" Version)"
  [[ "$current_version" == *+bbrv3.* ]] || die "Not a BBRv3 package: $package"
  [[ -z "$version" || "$version" == "$current_version" ]] || die 'Mixed package versions.'
  version="$current_version"
  # Verify every selected deb, including any extra file not in SHA256SUMS.
  digest="$(sha256sum "$package")"
  digest="${digest%% *}"
  grep -Fx -- "$digest  ${package#./}" SHA256SUMS >/dev/null || die "Unlisted package: $package"
  if [[ "$name" == linux-image-unsigned-* ]]; then
    [[ -z "$expected" ]] || die 'Multiple kernel images.'
    expected="${name#linux-image-unsigned-}"
  fi
done
[[ "$expected" =~ ^7\.0\.0-1[0-9]{4,}-generic$ ]] || die 'Missing or unexpected custom kernel image.'
[[ "$(uname -r)" != "$expected" ]] || die 'Target release is already running; use test, or upgrade from a different kernel to avoid replacing loaded modules.'
# Dependency failures must stop before package installation or reboot.
apt-get --simulate --no-remove install "${packages[@]}"
apt-get --yes --no-remove install "${packages[@]}"
[[ -s "/boot/vmlinuz-$expected" && -s "/boot/initrd.img-$expected" ]] || die 'Missing kernel or initramfs.'
update-grub
install -d -m 0700 "$state"
install -m 0755 "${BASH_SOURCE[0]}" "$state/install-bbrv3.sh"
install -m 0755 enable-bbrv3.sh "$state/enable-bbrv3.sh"
install -m 0644 bbrv3.sysctl.conf "$state/bbrv3.sysctl.conf"
printf '%s\n' "$expected" > "$state/expected-release"
cat > /etc/systemd/system/bbrv3-verify.service <<'UNIT'
[Unit]
Description=Enable and smoke-test the installed BBRv3 kernel
After=network.target
ConditionPathExists=/var/lib/bbrv3-installer/expected-release
[Service]
Type=oneshot
ExecStart=/var/lib/bbrv3-installer/install-bbrv3.sh test
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable bbrv3-verify.service
printf 'Installed %s. Select this kernel in GRUB. After boot: journalctl -u bbrv3-verify -b --no-pager\n' "$expected"
printf 'Original kernels are retained. This script does not change your GRUB default.\n'
if [[ "${2:-}" == --reboot ]]; then systemctl reboot; fi
