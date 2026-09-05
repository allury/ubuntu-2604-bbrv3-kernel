#!/usr/bin/env bash
set -euo pipefail

source_version="${1:?Usage: customize-ubuntu-package.sh <source-version> <custom-abi> <patch-revision>}"
custom_abi="${2:?Usage: customize-ubuntu-package.sh <source-version> <custom-abi> <patch-revision>}"
patch_revision="${3:?Usage: customize-ubuntu-package.sh <source-version> <custom-abi> <patch-revision>}"
changelog="debian.master/changelog"
generic_vars="debian.master/control.d/vars.generic"

if [[ "$source_version" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-([0-9]+)\.([0-9]+(\.[0-9]+)*)$ ]]; then
  upstream_version="${BASH_REMATCH[1]}"
  vendor_upload="${BASH_REMATCH[3]}"
else
  printf 'ERROR: Invalid source version: %s\n' "$source_version" >&2
  exit 1
fi
[[ "$custom_abi" =~ ^[0-9]+$ ]] ||
  { printf 'ERROR: Invalid custom ABI: %s\n' "$custom_abi" >&2; exit 1; }
[[ "$patch_revision" =~ ^[1-9][0-9]*$ ]] ||
  { printf 'ERROR: Invalid BBRv3 patch revision: %s\n' "$patch_revision" >&2; exit 1; }

actual_source_version="$(dpkg-parsechangelog -l"$changelog" -S Version)"
[[ "$actual_source_version" == "$source_version" ]] ||
  { printf 'ERROR: Source tag declares %s, expected %s.\n' "$actual_source_version" "$source_version" >&2; exit 1; }

# Ubuntu's packaging derives the ABI from the part before the first dot in the
# Debian revision. The vendor upload number remains in the version so later
# uploads of the same ABI still receive a monotonically newer custom package.
package_version="$upstream_version-$custom_abi.$vendor_upload+bbrv3.$patch_revision"
sed -E -i "1s/^linux \([^)]*\)/linux ($package_version)/" "$changelog"

actual_package_version="$(dpkg-parsechangelog -l"$changelog" -S Version)"
[[ "$actual_package_version" == "$package_version" ]] ||
  { printf 'ERROR: Custom package version was not applied.\n' >&2; exit 1; }

# Ubuntu's generic package expects a separately built ZFS package for the
# matching ABI. Keep that relationship intact. The workflow builds a real
# linux-main-modules-zfs package against these exact custom headers before it
# allows the kernel packages to be published.
zfs_dependency='depends="linux-main-modules-zfs-PKGVER-ABINUM-generic [amd64 arm64 ppc64el s390x]"'
grep -Fxq "$zfs_dependency" "$generic_vars" ||
  { printf 'ERROR: Expected Canonical ZFS dependency was not found in %s.\n' "$generic_vars" >&2; exit 1; }

printf 'Custom package version: %s\n' "$package_version"
printf 'Custom kernel release: %s-%s-generic\n' "$upstream_version" "$custom_abi"
printf '%s\n' 'External ZFS dependency: retained for the matching custom package.'
