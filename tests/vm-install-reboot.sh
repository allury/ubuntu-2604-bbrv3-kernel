#!/usr/bin/env bash
# Install a BBRv3 release in a full Ubuntu 26.04 cloud-image VM with the
# independent installer's own installation logic, reboot through GRUB and wait
# for the installer's boot-time verification service.
#
# tests/qemu-boot-smoke.sh starts the kernel directly with a minimal
# initramfs. This test covers what a server goes through instead: package
# scripts, the generated initramfs, the GRUB default entry, the root file
# system and systemd. It runs on CI runners and needs qemu-system-x86,
# qemu-utils, ubuntu-cloudimage-keyring, gpgv, curl and python3. It uses KVM
# when /dev/kvm is accessible and falls back to slow TCG emulation otherwise.
set -euo pipefail

usage='Usage: vm-install-reboot.sh <release-dir> <kernel-release>'
release_dir="${1:?$usage}"
kernel_release="${2:?$usage}"
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir=vm
console_log=vm-console.log
image_base=https://cloud-images.ubuntu.com/releases/resolute/release
image_name=ubuntu-26.04-server-cloudimg-amd64.img
cloud_image_keyring=/usr/share/keyrings/ubuntu-cloudimage-keyring.gpg
http_port=8000
# QEMU's user network exposes the host's loopback to the guest as 10.0.2.2.
guest_base_url="http://10.0.2.2:$http_port"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$kernel_release" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-generic$ ]] ||
  die "Unexpected kernel release: $kernel_release"
[[ -s "$release_dir/SHA256SUMS" ]] || die "$release_dir has no SHA256SUMS."
[[ ! -e "$work_dir" ]] || die "Remove the existing $work_dir directory first."
release_dir="$(cd -- "$release_dir" && pwd)"
mkdir -p "$work_dir/http"

# Boot only a cloud image whose checksum Ubuntu signed.
curl -fsSL --retry 3 -o "$work_dir/SHA256SUMS" "$image_base/SHA256SUMS"
curl -fsSL --retry 3 -o "$work_dir/SHA256SUMS.gpg" "$image_base/SHA256SUMS.gpg"
gpgv --keyring "$cloud_image_keyring" "$work_dir/SHA256SUMS.gpg" "$work_dir/SHA256SUMS"
curl -fsSL --retry 3 -o "$work_dir/$image_name" "$image_base/$image_name"
(cd "$work_dir" && sha256sum --check --strict --ignore-missing SHA256SUMS)
qemu-img create -q -f qcow2 -F qcow2 -b "$image_name" "$work_dir/disk.qcow2" 20G

# The guest reads its NoCloud seed, the release and the test scripts from
# this directory; the seed location is passed in the SMBIOS serial number.
ln -s "$release_dir" "$work_dir/http/release"
install -m 0644 "$repo_root/installer/install.sh" "$work_dir/http/install.sh"
install -m 0644 "$repo_root/tests/vm-guest-install.sh" "$work_dir/http/vm-guest-install.sh"
printf 'instance-id: bbrv3-acceptance\nlocal-hostname: bbrv3-acceptance\n' > "$work_dir/http/meta-data"
: > "$work_dir/http/vendor-data"
# bootcmd runs before network-online.target, which the apt-daily jobs wait
# for, so the first-boot updates are cancelled before they start and cannot
# hold the dpkg lock during the installation.
cat > "$work_dir/http/user-data" <<EOF
#cloud-config
bootcmd:
  - [systemctl, --no-block, stop, apt-daily.timer, apt-daily-upgrade.timer, apt-daily.service, apt-daily-upgrade.service]
runcmd:
  - [bash, -c, "curl -fsS $guest_base_url/vm-guest-install.sh -o /root/vm-guest-install.sh && bash /root/vm-guest-install.sh $guest_base_url $kernel_release > /dev/ttyS0 2>&1"]
EOF
python3 -m http.server "$http_port" --bind 127.0.0.1 --directory "$work_dir/http" > "$work_dir/http.log" 2>&1 &
http_server=$!
trap 'kill "$http_server" 2>/dev/null || true' EXIT
for _ in $(seq 50); do
  curl -fs -o /dev/null "http://127.0.0.1:$http_port/meta-data" && break
  sleep 0.2
done
curl -fs -o /dev/null "http://127.0.0.1:$http_port/meta-data" || die 'The seed HTTP server did not start.'

# The guest prints a VM_* marker at each stage. A stage that prints nothing
# new for stall_limit is treated as stuck instead of waiting for time_limit.
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  accel=(-accel kvm -cpu host)
  accelerator=KVM
  time_limit=$(( 45 * 60 ))
  stall_limit=$(( 15 * 60 ))
else
  printf '%s\n' 'WARNING: /dev/kvm is not usable; falling back to much slower TCG emulation.' >&2
  accel=(-accel tcg -cpu max)
  accelerator=TCG
  time_limit=$(( 110 * 60 ))
  stall_limit=$(( 45 * 60 ))
fi
# The kernel's own boot and reboot lines also count, so a stall can be told
# apart: installing, restarting, or booting the new kernel.
marker_pattern='VM_(INSTALL_START|PHASE|INSTALL_READY|ACCEPTANCE_[A-Z]+)|Linux version [0-9][^ ]*|reboot: [A-Z][a-z]+( [a-z]+)*'

# GitHub Actions annotations stay readable without signing in, unlike the
# job log, so the outcome and the end of the console are reported there too.
annotate() {
  local message="$3"
  message="${message//'%'/'%25'}"
  message="${message//$'\r'/}"
  message="${message//$'\n'/'%0A'}"
  # The console often ends without a newline, and a workflow command is only
  # recognised at the start of a line.
  printf '\n::%s title=%s::%s\n' "$1" "$2" "$message"
}

# The guest reboots once into the new kernel and powers off after reporting.
: > "$console_log"
qemu-system-x86_64 \
  "${accel[@]}" \
  -machine q35 \
  -smp 4 \
  -m 4096 \
  -display none \
  -monitor none \
  -serial "file:$console_log" \
  -drive "file=$work_dir/disk.qcow2,if=virtio,format=qcow2" \
  -nic user,model=virtio-net-pci,ipv6=off \
  -smbios "type=1,serial=ds=nocloud;s=$guest_base_url/" &
qemu_pid=$!
tail -n +1 -F --pid="$qemu_pid" "$console_log" &
tail_pid=$!
vm_started=$SECONDS
markers_seen=0
last_progress=$SECONDS
stopped_reason=''
while kill -0 "$qemu_pid" 2>/dev/null; do
  markers="$(grep -acE "$marker_pattern" "$console_log" || true)"
  if (( markers != markers_seen )); then
    markers_seen=$markers
    last_progress=$SECONDS
  fi
  if (( SECONDS - vm_started > time_limit )); then
    stopped_reason="the VM did not finish within $(( time_limit / 60 )) minutes"
  elif (( SECONDS - last_progress > stall_limit )); then
    stopped_reason="the guest printed no new progress marker for $(( stall_limit / 60 )) minutes"
  fi
  if [[ -n "$stopped_reason" ]]; then
    kill "$qemu_pid" 2>/dev/null || true
    break
  fi
  sleep 5
done
qemu_status=0
wait "$qemu_pid" || qemu_status=$?
wait "$tail_pid" || true

progress="$(grep -aoE "($marker_pattern)[^[:cntrl:]]*" "$console_log" | cut -c1-120 || true)"
summary="Accelerator $accelerator, VM ran $(( (SECONDS - vm_started) / 60 )) min, QEMU exit status $qemu_status.
Progress markers:
${progress:-none}"
if [[ -z "$stopped_reason" && "$qemu_status" -eq 0 ]] &&
  grep -aFq "VM_ACCEPTANCE_PASS: booted $kernel_release," "$console_log"; then
  annotate notice 'VM acceptance passed' "$summary"
  exit 0
fi
failure="${stopped_reason:-the VM stopped without passing the installer verification}"
console_tail="$(sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g' "$console_log" | LC_ALL=C tr -cd '\11\12\40-\176' |
  grep -v '^[[:space:]]*$' | tail -n 25 | cut -c1-160 || true)"
annotate error 'VM acceptance failed' "$failure.
$summary

Last console lines:
$console_tail"
die "$failure."
