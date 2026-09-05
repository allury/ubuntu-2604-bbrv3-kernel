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
[[ "$kernel_release" =~ ^7\.0\.0-[0-9]+-generic$ ]] ||
  die "Unexpected custom kernel release: $kernel_release"
[[ "$package_version" =~ ^7\.0\.0-[0-9]+\.[0-9]+\+bbrv3\.[1-9][0-9]*$ ]] ||
  die "Unexpected package version: $package_version"
[[ "$source_version" =~ ^7\.0\.0-[0-9]+\.[0-9]+$ ]] ||
  die "Unexpected Ubuntu source version: $source_version"

abi_release="${kernel_release%-generic}"
required_image="linux-image-unsigned-$kernel_release"
required_modules="linux-modules-$kernel_release"
required_flavour_headers="linux-headers-$kernel_release"
required_common_headers="linux-headers-$abi_release"
required_buildinfo="linux-buildinfo-$kernel_release"

mapfile -t packages < <(find "$release_dir" -maxdepth 1 -type f -name '*.deb' -printf '%f\n' | sort)
(( ${#packages[@]} > 0 )) || die "No .deb artifacts found."

declare -A package_paths=()
manifest_tmp="$(mktemp)"
unpack_dir="$(mktemp -d)"
trap 'rm -f "$manifest_tmp"; rm -rf "$unpack_dir"' EXIT

printf 'File\tPackage\tVersion\tArchitecture\tSHA256\n' > "$manifest_tmp"
for package_name in "${packages[@]}"; do
  package_path="$release_dir/$package_name"
  deb_name="$(dpkg-deb -f "$package_path" Package)"
  deb_version="$(dpkg-deb -f "$package_path" Version)"
  deb_arch="$(dpkg-deb -f "$package_path" Architecture)"
  expected_arch="amd64"

  [[ "$deb_name" != *dbgsym* ]] || die "Debug symbol package was produced: $deb_name"
  [[ "$deb_version" == "$package_version" ]] ||
    die "Unexpected package version in $package_name: $deb_version"
  [[ "$deb_name" == "$required_common_headers" ]] && expected_arch="all"
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
  "$required_buildinfo"; do
  [[ -n "${package_paths[$required_package]:-}" ]] ||
    die "Required package was not produced: $required_package"
done

image_depends="$(dpkg-deb -f "${package_paths[$required_image]}" Depends)"
grep -Fq "$required_modules" <<<"$image_depends" ||
  die "$required_image does not depend on $required_modules"
flavour_headers_depends="$(dpkg-deb -f "${package_paths[$required_flavour_headers]}" Depends)"
grep -Fq "$required_common_headers" <<<"$flavour_headers_depends" ||
  die "$required_flavour_headers does not depend on $required_common_headers"

modules_package="${package_paths[$required_modules]}"
if ! dpkg-deb -c "$modules_package" |
  grep -E "/usr/lib/modules/$kernel_release/kernel/net/ipv4/tcp_bbr\\.ko(\\.(xz|zst))?$" >/dev/null; then
  die "BBR module is missing from the modules package."
fi

dpkg-deb -x "$modules_package" "$unpack_dir"
module_path="$(find "$unpack_dir/usr/lib/modules/$kernel_release" -type f -name 'tcp_bbr.ko*' -print -quit)"
[[ -n "$module_path" ]] || die "Unable to extract tcp_bbr from the modules package."

module_version="$(modinfo -F version "$module_path" || true)"
[[ "$module_version" == "3" ]] ||
  die "tcp_bbr module is not BBRv3 (modinfo version: ${module_version:-missing})"
module_vermagic="$(modinfo -F vermagic "$module_path" || true)"
[[ "$module_vermagic" == "$kernel_release"* ]] ||
  die "tcp_bbr vermagic does not match $kernel_release: ${module_vermagic:-missing}"

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
  printf '%s\n' 'These packages are intentionally unsigned and coexist with Canonical kernel packages.'
  printf '%s\n' 'Secure Boot requires local signing and MOK enrollment, or it must be disabled before booting this kernel.'
} > "$release_dir/RELEASE-NOTES.md"

printf 'Verified %d Debian packages for %s.\n' "${#packages[@]}" "$kernel_release"
