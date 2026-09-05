#!/usr/bin/env bash
set -euo pipefail

requested_version="${1:-auto}"
readonly patch_revision=1

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

emit() {
  local key="$1"
  local value="$2"

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
  else
    printf '%s=%s\n' "$key" "$value"
  fi
}

latest_released_resolute_linux_version() {
  local image_package
  local package_metadata
  local source_version

  command -v apt-cache >/dev/null ||
    die "Automatic resolution requires apt-cache from an Ubuntu 26.04 environment."

  # Resolve the supported Ubuntu kernel from the signed APT metadata rather
  # than choosing the newest Launchpad Git tag, which may be unreleased.
  image_package="$(
    apt-cache depends linux-image-generic 2>/dev/null |
      awk '$1 == "Depends:" && $2 ~ /^linux-image-7\.0\.0-[0-9]+-generic$/ { print $2; exit }'
  )"
  [[ -n "$image_package" ]] ||
    die "Could not resolve the linux-image-generic dependency from APT metadata."

  package_metadata="$(apt-cache show --no-all-versions "$image_package")"
  source_version="$(
    awk '
      /^Source: linux \(7\.0\.0-[0-9]+\.[0-9]+\)$/ {
        value = $0
        sub(/^Source: linux \(/, "", value)
        sub(/\)$/, "", value)
        print value
        exit
      }
    ' <<<"$package_metadata"
  )"

  # A binary package sourced from linux normally has the same version. Keep
  # this fallback for archive metadata that omits the parenthesized Source
  # version, but still validate the exact Ubuntu version format below.
  if [[ -z "$source_version" ]]; then
    source_version="$(
      awk '/^Version: 7\.0\.0-[0-9]+\.[0-9]+$/ { print $2; exit }' <<<"$package_metadata"
    )"
  fi

  [[ -n "$source_version" ]] ||
    die "Could not determine the source version for $image_package."
  printf '%s\n' "$source_version"
}

if [[ "$requested_version" == "auto" ]]; then
  source_version="$(latest_released_resolute_linux_version)"
else
  source_version="$requested_version"
fi

if [[ "$source_version" =~ ^7\.0\.0-([0-9]+)\.([0-9]+)$ ]]; then
  vendor_abi="${BASH_REMATCH[1]}"
  vendor_upload="${BASH_REMATCH[2]}"
else
  die "Expected an Ubuntu linux source version such as 7.0.0-30.30; got '$source_version'."
fi

# Keep custom packages separate from Canonical's ABI namespace. For example,
# source 7.0.0-30.30 produces a bootable 7.0.0-10030-generic kernel.
custom_abi="$((10000 + 10#$vendor_abi))"
source_tag="Ubuntu-$source_version"
kernel_release="7.0.0-$custom_abi-generic"
package_version="7.0.0-$custom_abi.$vendor_upload+bbrv3.$patch_revision"
release_tag="ubuntu-26.04-bbrv3-$source_version-p$patch_revision"

emit source_version "$source_version"
emit source_tag "$source_tag"
emit vendor_abi "$vendor_abi"
emit vendor_upload "$vendor_upload"
emit custom_abi "$custom_abi"
emit kernel_release "$kernel_release"
emit package_version "$package_version"
emit patch_revision "$patch_revision"
emit release_tag "$release_tag"
