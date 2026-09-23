#!/usr/bin/env bash
# Runs as root inside the VM acceptance test, started by cloud-init on the
# first boot. It downloads a release from the test host, installs it with the
# independent installer's embedded installation logic and lets the installer
# reboot. On the next boot a oneshot unit reports the result of the
# installer's own verification service to the serial console and powers off.
set -euo pipefail

usage='Usage: vm-guest-install.sh <base-url> <kernel-release>'
base_url="${1:?$usage}"
kernel_release="${2:?$usage}"
release_dir=/var/tmp/bbrv3-release
started=/var/lib/bbrv3-acceptance/started

fail() {
  printf 'VM_ACCEPTANCE_FAIL: %s\n' "$*"
  systemctl poweroff
  exit 1
}
trap 'fail "installation step failed at line $LINENO"' ERR

# cloud-init runs this once per instance; never install twice.
[[ ! -e "$started" ]] || exit 0
mkdir -p "$(dirname -- "$started")"
touch "$started"
printf 'VM_INSTALL_START: %s\n' "$kernel_release"

# A fresh image starts background apt jobs; they must not hold the dpkg lock
# while the installer runs.
systemctl stop apt-daily.timer apt-daily-upgrade.timer apt-daily.service \
  apt-daily-upgrade.service unattended-upgrades.service || true
printf 'DPkg::Lock::Timeout "600";\n' > /etc/apt/apt.conf.d/99bbrv3-acceptance
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l

# Ubuntu cloud images first try to boot without an initramfs
# (GRUB_FORCE_PARTUUID). Turn that off so the new kernel boots the way most
# servers boot it, through the initramfs its packages generate; the report
# checks that the initramfs was really used.
printf 'GRUB_FORCE_PARTUUID=\n' > /etc/default/grub.d/99-bbrv3-acceptance.cfg

# Fetch every file the release lists, as the installer does from GitHub.
mkdir -p "$release_dir"
cd "$release_dir"
curl -fsS "$base_url/release/SHA256SUMS" -o SHA256SUMS
while read -r _ name; do
  name="${name#\*}"
  [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || fail "unexpected file name in SHA256SUMS: $name"
  curl -fsS "$base_url/release/$name" -o "$name"
done < SHA256SUMS
sha256sum --check --strict --quiet SHA256SUMS
compgen -G "linux-image-unsigned-${kernel_release}_*.deb" > /dev/null ||
  fail "the release does not contain linux-image-unsigned-$kernel_release"

# Run exactly the installation logic that installer/install.sh embeds, the way
# it runs it after downloading and verifying a release.
curl -fsS "$base_url/install.sh" -o /root/bbrv3-installer.sh
extract_embedded() {
  sed -n "/<<'$1'\$/,/^$1\$/p" /root/bbrv3-installer.sh | sed '1d;$d'
}
mkdir .installer-runtime
extract_embedded BBRV3_ENABLE_V1_1 > .installer-runtime/enable-bbrv3.sh
extract_embedded BBRV3_CONFIG_V1_1 > .installer-runtime/bbrv3.sysctl.conf
extract_embedded BBRV3_INSTALLER_V1 > .installer-runtime/install-bbrv3.sh
for part in enable-bbrv3.sh bbrv3.sysctl.conf install-bbrv3.sh; do
  [[ -s ".installer-runtime/$part" ]] ||
    fail "installer/install.sh no longer embeds $part the way this test extracts it"
done

# Report the installer's verification service on the next boot.
cat > /usr/local/sbin/bbrv3-acceptance-report <<'REPORT'
#!/usr/bin/env bash
set -uo pipefail
exec > /dev/ttyS0 2>&1
expected="$(cat /var/lib/bbrv3-installer/expected-release 2>/dev/null)"
booted="$(uname -r)"
result=PASS
[[ -n "$expected" && "$booted" == "$expected" ]] || result=FAIL
systemctl is-active --quiet bbrv3-verify.service || result=FAIL
initramfs=used
journalctl -k -b --no-pager | grep -Eq 'Trying to unpack rootfs image as initramfs|Freeing initrd memory' ||
  { initramfs=not-used; result=FAIL; }
echo '--- bbrv3-verify.service ---'
journalctl -u bbrv3-verify.service -b --no-pager
echo '--- failed units ---'
systemctl --failed --no-pager
echo '--- kernel messages at warning level or above ---'
journalctl -k -b -p warning --no-pager | tail -n 80
printf 'Kernel taint: %s\n' "$(cat /proc/sys/kernel/tainted)"
printf 'VM_ACCEPTANCE_%s: booted %s, expected %s, initramfs %s, congestion control %s, qdisc %s, tcp_bbr version %s\n' \
  "$result" "$booted" "${expected:-missing}" "$initramfs" \
  "$(sysctl -n net.ipv4.tcp_congestion_control)" "$(sysctl -n net.core.default_qdisc)" \
  "$(cat /sys/module/tcp_bbr/version 2>/dev/null || echo missing)"
systemctl poweroff
REPORT
chmod 0755 /usr/local/sbin/bbrv3-acceptance-report
cat > /etc/systemd/system/bbrv3-acceptance-report.service <<'UNIT'
[Unit]
Description=Report the BBRv3 installer verification to the serial console
After=bbrv3-verify.service
ConditionPathExists=/var/lib/bbrv3-installer/expected-release

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/bbrv3-acceptance-report

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable bbrv3-acceptance-report.service

apt-get -o Acquire::Retries=3 update
echo 'VM_INSTALL_READY'
bash .installer-runtime/install-bbrv3.sh install --reboot
