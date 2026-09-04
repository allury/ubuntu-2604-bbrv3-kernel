#!/usr/bin/env bash
set -euo pipefail

source_version="${1:?Usage: customize-ubuntu-package.sh <source-version> <custom-abi>}"
custom_abi="${2:?Usage: customize-ubuntu-package.sh <source-version> <custom-abi>}"
changelog="debian.master/changelog"

[[ "$source_version" =~ ^7\.0\.0-[0-9]+\.[0-9]+$ ]] ||
  { printf 'ERROR: Invalid source version: %s\n' "$source_version" >&2; exit 1; }
[[ "$custom_abi" =~ ^[0-9]+$ ]] ||
  { printf 'ERROR: Invalid custom ABI: %s\n' "$custom_abi" >&2; exit 1; }

actual_source_version="$(dpkg-parsechangelog -l"$changelog" -S Version)"
[[ "$actual_source_version" == "$source_version" ]] ||
  { printf 'ERROR: Source tag declares %s, expected %s.\n' "$actual_source_version" "$source_version" >&2; exit 1; }

package_version="7.0.0-$custom_abi.1+bbrv3"
sed -E -i "1s/^linux \([^)]*\)/linux ($package_version)/" "$changelog"

actual_package_version="$(dpkg-parsechangelog -l"$changelog" -S Version)"
[[ "$actual_package_version" == "$package_version" ]] ||
  { printf 'ERROR: Custom package version was not applied.\n' >&2; exit 1; }

printf 'Custom package version: %s\n' "$package_version"
printf 'Custom kernel release: 7.0.0-%s-generic\n' "$custom_abi"
