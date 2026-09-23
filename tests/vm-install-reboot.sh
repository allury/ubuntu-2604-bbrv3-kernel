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
cat > "$work_dir/http/user-data" <<EOF
#cloud-config
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

if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  accel=(-accel kvm -cpu host)
  time_limit=30m
else
  printf '%s\n' 'WARNING: /dev/kvm is not usable; falling back to much slower TCG emulation.' >&2
  accel=(-accel tcg -cpu max)
  time_limit=100m
fi

# The guest reboots once into the new kernel and powers off after reporting.
set +e
timeout "$time_limit" qemu-system-x86_64 \
  "${accel[@]}" \
  -machine q35 \
  -smp 4 \
  -m 4096 \
  -display none \
  -monitor none \
  -serial stdio \
  -drive "file=$work_dir/disk.qcow2,if=virtio,format=qcow2" \
  -nic user,model=virtio-net-pci \
  -smbios "type=1,serial=ds=nocloud;s=$guest_base_url/" \
  2>&1 | tee "$console_log"
qemu_status="${PIPESTATUS[0]}"
set -e

grep -Fq 'VM_INSTALL_START' "$console_log" ||
  die 'The guest never started the installation; check the cloud-init seed and network in the console log.'
grep -F 'VM_ACCEPTANCE_' "$console_log" || true
grep -Fq "VM_ACCEPTANCE_PASS: booted $kernel_release," "$console_log" ||
  die "The VM did not reboot into $kernel_release and pass the installer's verification (QEMU exit status $qemu_status)."
[[ "$qemu_status" -eq 0 ]] || die "QEMU exited with status $qemu_status."
