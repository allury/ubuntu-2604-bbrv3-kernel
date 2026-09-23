#!/usr/bin/env bash
# Boot a packaged BBRv3 kernel in QEMU with a minimal BusyBox initramfs, load
# BBRv3 and the matching OpenZFS modules, and exercise a TCP transfer.
# The release workflow runs it on freshly built packages, and the repository
# checks run it on the latest published release. It needs busybox-static,
# cpio, gcc, libc6-dev, kmod, qemu-system-x86, zstd and sudo for mknod.
set -euo pipefail

usage='Usage: qemu-boot-smoke.sh <release-dir> <kernel-release>'
release_dir="${1:?$usage}"
kernel_release="${2:?$usage}"
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir=qemu
console_log=qemu-console.log

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$kernel_release" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-generic$ ]] ||
  die "Unexpected kernel release: $kernel_release"
[[ ! -e "$work_dir" ]] || die "Remove the existing $work_dir directory first."

single_package() {
  local pattern="$1"
  local -a matches
  mapfile -t matches < <(find "$release_dir" -maxdepth 1 -type f -name "$pattern" -print)
  (( ${#matches[@]} == 1 )) || die "Expected one $pattern in $release_dir, found ${#matches[@]}."
  printf '%s\n' "${matches[0]}"
}

image_package="$(single_package "linux-image-unsigned-${kernel_release}_*.deb")"
modules_package="$(single_package "linux-modules-${kernel_release}_*.deb")"
zfs_package="$(single_package "linux-main-modules-zfs-${kernel_release}_*.deb")"
mkdir -p "$work_dir/image" "$work_dir/modules" "$work_dir/root/bin" "$work_dir/root/dev" \
  "$work_dir/root/proc" "$work_dir/root/sys" "$work_dir/root/modules"
dpkg-deb -x "$image_package" "$work_dir/image"
dpkg-deb -x "$modules_package" "$work_dir/modules"
dpkg-deb -x "$zfs_package" "$work_dir/modules"
kernel_image="$work_dir/image/boot/vmlinuz-$kernel_release"
[[ -s "$kernel_image" ]] || die "The image package does not contain vmlinuz-$kernel_release."

# The initramfs has no module loader, so each module must be self-contained
# apart from the dependencies loaded before it.
extract_module() {
  local module_name="$1"
  local expected_depends="$2"
  local target="$work_dir/root/modules/$module_name.ko"
  local module_path
  local depends

  module_path="$(find "$work_dir/modules/usr/lib/modules/$kernel_release" -type f -name "$module_name.ko*" -print -quit)"
  [[ -n "$module_path" ]] || die "$module_name is missing from the module packages."
  case "$module_path" in
    *.ko.zst) zstd --quiet --decompress --stdout "$module_path" > "$target" ;;
    *.ko.xz) xz --decompress --stdout "$module_path" > "$target" ;;
    *.ko) cp -- "$module_path" "$target" ;;
    *) die "Unsupported module file: $module_path" ;;
  esac
  depends="$(modinfo -F depends "$target")"
  [[ "$depends" == "$expected_depends" ]] ||
    die "$module_name depends on '${depends}', expected '${expected_depends}'."
}
extract_module sch_fq ''
extract_module tcp_bbr ''
extract_module spl ''
extract_module zfs spl

modinfo -F version "$work_dir/root/modules/zfs.ko" > "$work_dir/root/zfs-expected-version"
[[ -s "$work_dir/root/zfs-expected-version" ]] || die 'The packaged OpenZFS module does not declare a version.'
install -m 0755 /bin/busybox "$work_dir/root/bin/busybox"
install -m 0755 "$repo_root/tests/qemu-init.sh" "$work_dir/root/init"
gcc -static -O2 -Wall -Wextra -Werror \
  "$repo_root/tests/qemu-bbr-smoke.c" -o "$work_dir/root/bbrv3-socket-smoke"
sudo mknod "$work_dir/root/dev/console" c 5 1
sudo mknod "$work_dir/root/dev/null" c 1 3
(cd "$work_dir/root" && find . -print0 | cpio --null --create --format=newc 2>/dev/null | gzip -9 > ../initramfs.cpio.gz)

set +e
timeout 180s qemu-system-x86_64 \
  -machine q35,accel=tcg \
  -cpu max \
  -smp 2 \
  -m 768M \
  -display none \
  -monitor none \
  -serial stdio \
  -no-reboot \
  -kernel "$kernel_image" \
  -initrd "$work_dir/initramfs.cpio.gz" \
  -append 'rdinit=/init console=ttyS0,115200 panic=-1' \
  2>&1 | tee "$console_log"
qemu_status="${PIPESTATUS[0]}"
set -e
grep -F 'BBRV3_SOCKET_PASS' "$console_log"
grep -F "BBRV3_QEMU_PASS: $kernel_release, module version 3" "$console_log"
grep -F 'ZFS_QEMU_PASS: module version ' "$console_log"
[[ "$qemu_status" -eq 0 ]] || die "QEMU exited with status $qemu_status."
