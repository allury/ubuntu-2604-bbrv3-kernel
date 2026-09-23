#!/usr/bin/env bash
# Runs as root inside the VM acceptance test, started by cloud-init on the
# first boot. It downloads a release from the test host, installs it with the
# independent installer's embedded installation logic and lets the installer
# reboot. On the next boot a oneshot unit reports the result of the
# installer's own verification service to the serial console and powers off.
set -Eeuo pipefail

usage='Usage: vm-guest-install.sh <base-url> <kernel-release>'
base_url="${1:?$usage}"
kernel_release="${2:?$usage}"
release_dir=/var/tmp/bbrv3-release
started=/var/lib/bbrv3-acceptance/started
log=/var/log/bbrv3-acceptance.log

# Everything this script and the installer print goes to $log. Only markers
# reach the serial console, each through a fresh open: serial-getty hangs up
# ttyS0 when it starts, after which a descriptor opened before that fails
# with EIO. Earlier runs died silently on exactly that write.
exec >> "$log" 2>&1

console() {
  printf '%s\n' "$*"
  printf '%s\n' "$*" > /dev/ttyS0 || true
}

# Any failure reports itself with the end of the log and powers the VM off at
# once, so the host does not wait for its time limit. The forced poweroff
# also skips services such as unattended-upgrades that can hold a normal
# shutdown for 30 minutes.
fail() {
  trap - ERR EXIT
  console "VM_ACCEPTANCE_FAIL: $*"
  {
    echo '--- network state ---'
    ip -brief address
    ip route
    resolvectl dns
  } >> "$log" 2>&1 || true
  { echo '--- end of the installation log ---'; tail -n 60 "$log"; } > /dev/ttyS0 2>&1 || true
  sleep 2
  systemctl poweroff --force
  exit 1
}
trap 'fail "line $LINENO failed: $BASH_COMMAND"' ERR
trap 'status=$?; (( status == 0 )) || fail "the installation script exited with status $status"' EXIT

phase() {
  console "VM_PHASE: $(date -u +%H:%M:%S) $*"
}

# cloud-init runs this once per instance; never install twice.
[[ ! -e "$started" ]] || exit 0
mkdir -p "$(dirname -- "$started")"
touch "$started"
console "VM_INSTALL_START: $kernel_release at $(date -u +%H:%M:%S)"

# cloud-init's bootcmd cancels the first-boot apt-daily jobs. Should one run
# anyway, wait for it instead of interrupting it, and never stop
# unattended-upgrades.service: its stop waits for a running upgrade for up
# to 30 minutes.
for unit in apt-daily.service apt-daily-upgrade.service; do
  while :; do
    case "$(systemctl show -p ActiveState --value "$unit")" in
      activating|active|deactivating|reloading) sleep 5 ;;
      *) break ;;
    esac
  done
done
phase 'no background apt job is running'
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l

# The installer resolves package dependencies from the Ubuntu archive. Bound
# every apt request, and fail early with the network state when the archive
# does not answer, instead of hanging at "Waiting for headers".
cat > /etc/apt/apt.conf.d/99bbrv3-acceptance <<'APT'
DPkg::Lock::Timeout "600";
Acquire::Retries "3";
Acquire::http::Timeout "30";
APT
codename="$(awk -F= '$1 == "VERSION_CODENAME" { print $2 }' /etc/os-release)"
mapfile -t archive_uris < <(awk '/^URIs:/ { for (i = 2; i <= NF; i++) print $i }' \
  /etc/apt/sources.list.d/ubuntu.sources | sort -u)
(( ${#archive_uris[@]} > 0 )) || fail 'no Ubuntu archive is configured in ubuntu.sources'
for uri in "${archive_uris[@]}"; do
  curl -fsS -o /dev/null --max-time 60 "${uri%/}/dists/$codename/Release" ||
    fail "the Ubuntu archive $uri did not answer within 60 seconds"
done
phase "Ubuntu archive reachable: ${archive_uris[*]}"

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
phase 'release downloaded and verified'

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
report=/var/log/bbrv3-acceptance-report.log
expected="$(cat /var/lib/bbrv3-installer/expected-release 2>/dev/null)"
booted="$(uname -r)"
result=PASS
[[ -n "$expected" && "$booted" == "$expected" ]] || result=FAIL
systemctl is-active --quiet bbrv3-verify.service || result=FAIL
initramfs=used
journalctl -k -b --no-pager | grep -Eq 'Trying to unpack rootfs image as initramfs|Freeing initrd memory' ||
  { initramfs=not-used; result=FAIL; }
{
  echo '--- bbrv3-verify.service ---'
  journalctl -u bbrv3-verify.service -b --no-pager
  echo '--- failed units ---'
  systemctl --failed --no-pager
  echo '--- kernel messages at warning level or above ---'
  journalctl -k -b -p warning --no-pager | tail -n 80
  printf 'Kernel taint: %s\n' "$(cat /proc/sys/kernel/tainted)"
} > "$report" 2>&1
marker="$(printf 'VM_ACCEPTANCE_%s: booted %s, expected %s, initramfs %s, congestion control %s, qdisc %s, tcp_bbr version %s' \
  "$result" "$booted" "${expected:-missing}" "$initramfs" \
  "$(sysctl -n net.ipv4.tcp_congestion_control)" "$(sysctl -n net.core.default_qdisc)" \
  "$(cat /sys/module/tcp_bbr/version 2>/dev/null || echo missing)")"
# Fresh opens of ttyS0, which serial-getty may have hung up already.
cat "$report" > /dev/ttyS0
printf '%s\n' "$marker" > /dev/ttyS0
sleep 2
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

apt-get update
console "VM_INSTALL_READY: $(date -u +%H:%M:%S)"
bash .installer-runtime/install-bbrv3.sh install --reboot
phase 'installer finished; rebooting into the new kernel'
