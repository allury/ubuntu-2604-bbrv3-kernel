#!/usr/bin/env bash
set -euo pipefail

release_dir="${1:?Usage: verify-artifacts.sh <release-dir> <kernel-release> <package-version> <source-version>}"
kernel_release="${2:?Usage: verify-artifacts.sh <release-dir> <kernel-release> <package-version> <source-version>}"
package_version="${3:?Usage: verify-artifacts.sh <release-dir> <kernel-release> <package-version> <source-version>}"
source_version="${4:?Usage: verify-artifacts.sh <release-dir> <kernel-release> <package-version> <source-version>}"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ -d "$release_dir" ]] || die "Release directory does not exist: $release_dir"
[[ "$kernel_release" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-generic$ ]] ||
  die "Unexpected custom kernel release: $kernel_release"
[[ "$package_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+\.[0-9]+(\.[0-9]+)*\+bbrv3\.[1-9][0-9]*$ ]] ||
  die "Unexpected package version: $package_version"
[[ "$source_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+\.[0-9]+(\.[0-9]+)*$ ]] ||
  die "Unexpected Ubuntu source version: $source_version"

abi_release="${kernel_release%-generic}"
required_image="linux-image-unsigned-$kernel_release"
required_modules="linux-modules-$kernel_release"
required_flavour_headers="linux-headers-$kernel_release"
required_common_headers="linux-headers-$abi_release"
required_buildinfo="linux-buildinfo-$kernel_release"
required_zfs="linux-main-modules-zfs-$kernel_release"
optional_rust="linux-lib-rust-$kernel_release"

mapfile -t packages < <(find "$release_dir" -maxdepth 1 -type f -name '*.deb' -printf '%f\n' | sort)
(( ${#packages[@]} > 0 )) || die "No .deb artifacts found."

declare -A package_paths=()
declare -A expected_architectures=(
  ["$required_image"]=amd64
  ["$required_modules"]=amd64
  ["$required_flavour_headers"]=amd64
  ["$required_common_headers"]=all
  ["$required_buildinfo"]=amd64
  ["$required_zfs"]=amd64
  ["$optional_rust"]=amd64
)
manifest_tmp="$(mktemp)"
unpack_dir="$(mktemp -d)"
module_listing="$(mktemp)"
zfs_listing="$(mktemp)"
trap 'rm -f "$manifest_tmp" "$module_listing" "$zfs_listing"; rm -rf "$unpack_dir"' EXIT

printf 'File\tPackage\tVersion\tArchitecture\tSHA256\n' > "$manifest_tmp"
for package_name in "${packages[@]}"; do
  package_path="$release_dir/$package_name"
  deb_name="$(dpkg-deb -f "$package_path" Package)"
  deb_version="$(dpkg-deb -f "$package_path" Version)"
  deb_arch="$(dpkg-deb -f "$package_path" Architecture)"
  [[ "$deb_name" != *dbgsym* ]] || die "Debug symbol package was produced: $deb_name"
  [[ "$deb_version" == "$package_version" ]] ||
    die "Unexpected package version in $package_name: $deb_version"
  [[ -n "${expected_architectures[$deb_name]:-}" ]] ||
    die "Unexpected package was produced: $deb_name"
  expected_arch="${expected_architectures[$deb_name]}"
  [[ "$deb_arch" == "$expected_arch" ]] ||
    die "Unexpected architecture in $package_name: $deb_arch (expected $expected_arch)"
  [[ -z "${package_paths[$deb_name]:-}" ]] || die "Duplicate package: $deb_name"

  package_paths["$deb_name"]="$package_path"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$package_name" "$deb_name" "$deb_version" "$deb_arch" \
    "$(sha256sum "$package_path" | awk '{print $1}')" >> "$manifest_tmp"
done

for required_package in \
  "$required_image" \
  "$required_modules" \
  "$required_flavour_headers" \
  "$required_common_headers" \
  "$required_buildinfo" \
  "$required_zfs"; do
  [[ -n "${package_paths[$required_package]:-}" ]] ||
    die "Required package was not produced: $required_package"
done

image_depends="$(dpkg-deb -f "${package_paths[$required_image]}" Depends)"
grep -Fq "$required_modules" <<<"$image_depends" ||
  die "$required_image does not depend on $required_modules"
flavour_headers_depends="$(dpkg-deb -f "${package_paths[$required_flavour_headers]}" Depends)"
grep -Fq "$required_common_headers" <<<"$flavour_headers_depends" ||
  die "$required_flavour_headers does not depend on $required_common_headers"

modules_depends="$(dpkg-deb -f "${package_paths[$required_modules]}" Depends)"
grep -Fq "$required_zfs" <<<"$modules_depends" ||
  die "$required_modules does not depend on $required_zfs"
grep -Fq 'wireless-regdb' <<<"$modules_depends" ||
  die "$required_modules unexpectedly lacks its wireless-regdb dependency"

zfs_depends="$(dpkg-deb -f "${package_paths[$required_zfs]}" Depends)"
grep -Fq 'kmod' <<<"$zfs_depends" || die "$required_zfs does not depend on kmod"
grep -Fq "linux-image-$kernel_release | linux-image-unsigned-$kernel_release" <<<"$zfs_depends" ||
  die "$required_zfs does not depend on the matching signed or unsigned image"
zfs_provides="$(dpkg-deb -f "${package_paths[$required_zfs]}" Provides)"
for provided_name in spl-dkms spl-modules zfs-dkms zfs-modules; do
  grep -Fwq "$provided_name" <<<"${zfs_provides//,/ }" ||
    die "$required_zfs does not provide $provided_name"
done

modules_package="${package_paths[$required_modules]}"
dpkg-deb -c "$modules_package" > "$module_listing"
if ! grep -E "/usr/lib/modules/$kernel_release/kernel/net/ipv4/tcp_bbr\\.ko(\\.(xz|zst))?$" "$module_listing" >/dev/null; then
  die "BBR module is missing from the modules package."
fi

dpkg-deb -x "$modules_package" "$unpack_dir"
module_path="$(find "$unpack_dir/usr/lib/modules/$kernel_release" -type f -name 'tcp_bbr.ko*' -print -quit)"
[[ -n "$module_path" ]] || die "Unable to extract tcp_bbr from the modules package."

module_version="$(modinfo -F version "$module_path" || true)"
[[ "$module_version" == "3" ]] ||
  die "tcp_bbr module is not BBRv3 (modinfo version: ${module_version:-missing})"
module_vermagic="$(modinfo -F vermagic "$module_path" || true)"
[[ "${module_vermagic%% *}" == "$kernel_release" ]] ||
  die "tcp_bbr vermagic does not match $kernel_release: ${module_vermagic:-missing}"

zfs_package="${package_paths[$required_zfs]}"
dpkg-deb -c "$zfs_package" > "$zfs_listing"
for zfs_module_name in spl zfs; do
  if ! grep -E "/usr/lib/modules/$kernel_release/ubuntu/dkms/zfs/$zfs_module_name\\.ko(\\.(xz|zst))?$" "$zfs_listing" >/dev/null; then
    die "$zfs_module_name is missing from $required_zfs"
  fi
done
dpkg-deb -x "$zfs_package" "$unpack_dir"
for zfs_module_name in spl zfs; do
  zfs_module_path="$(find "$unpack_dir/usr/lib/modules/$kernel_release" -type f -name "$zfs_module_name.ko*" -print -quit)"
  [[ -n "$zfs_module_path" ]] || die "Unable to extract $zfs_module_name from $required_zfs"
  zfs_vermagic="$(modinfo -F vermagic "$zfs_module_path" || true)"
  [[ "${zfs_vermagic%% *}" == "$kernel_release" ]] ||
    die "$zfs_module_name vermagic does not match $kernel_release: ${zfs_vermagic:-missing}"
  [[ -n "$(modinfo -F signer "$zfs_module_path" || true)" ]] ||
    die "$zfs_module_name is not signed with the custom kernel build key"
done
[[ -n "$(modinfo -F version "$(find "$unpack_dir/usr/lib/modules/$kernel_release" -type f -name 'zfs.ko*' -print -quit)" || true)" ]] ||
  die 'The packaged OpenZFS module does not declare a version.'

mv "$manifest_tmp" "$release_dir/PACKAGE-MANIFEST.tsv"
(
  cd "$release_dir"
  sha256sum -- *.deb > SHA256SUMS
)

{
  printf '%s\n\n' '# Ubuntu 26.04 BBRv3 kernel'
  printf '%s\n' "- Ubuntu source package: linux $source_version"
  printf '%s\n' "- Custom kernel release: $kernel_release"
  printf '%s\n' "- Package version: $package_version"
  printf '%s\n' '- Congestion-control selector after boot: bbr (not bbr3)'
  printf '%s\n\n' '- BBR module version verified from the package: 3'
  printf '%s\n' 'The custom kernel coexists with Canonical kernel packages; keep a Canonical fallback installed.'
  printf '%s\n' "A matching $required_zfs package is included and its locally signed spl/zfs module vermagic was verified."
  printf '%s\n' 'The kernel image is not Canonical-signed. Secure Boot requires image signing and trust enrollment, or it must be disabled.'
} > "$release_dir/RELEASE-NOTES.md"

printf 'Verified %d Debian packages for %s.\n' "${#packages[@]}" "$kernel_release"
