#!/usr/bin/env bash
set -euo pipefail

release_dir="${1:?Usage: verify-artifacts.sh <release-dir> <kernel-release> <package-version> <source-version>}"
kernel_release="${2:?Usage: verify-artifacts.sh <release-dir> <kernel-release> <package-version> <source-version>}"
package_version="${3:?Usage: verify-artifacts.sh <release-dir> <kernel-release> <package-version> <source-version>}"
source_version="${4:?Usage: verify-artifacts.sh <release-dir> <kernel-release> <package-version> <source-version>}"

mapfile -t packages < <(find "$release_dir" -maxdepth 1 -type f -name '*.deb' -printf '%f\n' | sort)
(( ${#packages[@]} > 0 )) || { printf 'ERROR: No .deb artifacts found.\n' >&2; exit 1; }

image_package=""
modules_package=""
for package_name in "${packages[@]}"; do
  package_path="$release_dir/$package_name"
  deb_name="$(dpkg-deb -f "$package_path" Package)"
  deb_version="$(dpkg-deb -f "$package_path" Version)"
  deb_arch="$(dpkg-deb -f "$package_path" Architecture)"

  [[ "$deb_arch" == "amd64" ]] ||
    { printf 'ERROR: Unexpected architecture in %s: %s\n' "$package_name" "$deb_arch" >&2; exit 1; }
  [[ "$deb_version" == "$package_version" ]] ||
    { printf 'ERROR: Unexpected package version in %s: %s\n' "$package_name" "$deb_version" >&2; exit 1; }
  [[ "$deb_name" != *dbgsym* ]] ||
    { printf 'ERROR: Debug symbol package was produced: %s\n' "$deb_name" >&2; exit 1; }

  [[ "$deb_name" == linux-image-unsigned-"$kernel_release" ]] && image_package="$package_path"
  [[ "$deb_name" == linux-modules-"$kernel_release" ]] && modules_package="$package_path"
done

[[ -n "$image_package" ]] ||
  { printf 'ERROR: linux-image-unsigned-%s was not produced.\n' "$kernel_release" >&2; exit 1; }
[[ -n "$modules_package" ]] ||
  { printf 'ERROR: linux-modules-%s was not produced.\n' "$kernel_release" >&2; exit 1; }

dpkg-deb -c "$modules_package" |
  grep -q "/usr/lib/modules/$kernel_release/kernel/net/ipv4/tcp_bbr\\.ko" ||
  { printf 'ERROR: BBR module is missing from the modules package.\n' >&2; exit 1; }

(
  cd "$release_dir"
  sha256sum -- *.deb > SHA256SUMS
)

cat > "$release_dir/RELEASE-NOTES.md" <<EOF
# Ubuntu 26.04 BBRv3 kernel

- Ubuntu source package: `linux $source_version`
- Custom kernel release: `$kernel_release`
- Package version: `$package_version`
- Congestion-control selector after boot: `bbr` (not `bbr3`)

These packages are intentionally unsigned and coexist with Canonical's
`7.0.0-*-generic` packages.  Secure Boot requires local signing and MOK
enrollment, or it must be disabled before booting this kernel.
EOF

printf 'Verified %d Debian packages for %s.\n' "${#packages[@]}" "$kernel_release"
