#!/usr/bin/env bash
set -euo pipefail

readonly ubuntu_kernel_repo="${UBUNTU_KERNEL_REPOSITORY:-https://git.launchpad.net/~ubuntu-kernel/ubuntu/+source/linux/+git/resolute}"
requested_version="${1:-auto}"

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

latest_resolute_linux_version() {
  git ls-remote --tags "$ubuntu_kernel_repo" 'Ubuntu-7.0.0-*' |
    awk '
      {
        tag = $2
        sub("^refs/tags/", "", tag)
        sub(/\^\{\}$/, "", tag)
        if (tag ~ /^Ubuntu-7\.0\.0-[0-9]+\.[0-9]+$/) {
          sub("^Ubuntu-", "", tag)
          print tag
        }
      }
    ' |
    sort -Vu |
    tail -n 1
}

if [[ "$requested_version" == "auto" ]]; then
  source_version="$(latest_resolute_linux_version)"
else
  source_version="$requested_version"
fi

[[ "$source_version" =~ ^7\.0\.0-[0-9]+\.[0-9]+$ ]] ||
  die "Expected an Ubuntu linux source version such as 7.0.0-30.30; got '$source_version'."

vendor_abi="${source_version#7.0.0-}"
vendor_abi="${vendor_abi%%.*}"
[[ "$vendor_abi" =~ ^[0-9]+$ ]] || die "Cannot determine the vendor ABI from '$source_version'."

# Keep custom packages separate from Canonical's ABI namespace.  For example,
# source 7.0.0-30.30 produces a bootable 7.0.0-10030-generic kernel.
custom_abi="$((10000 + 10#$vendor_abi))"
source_tag="Ubuntu-$source_version"
kernel_release="7.0.0-$custom_abi-generic"
package_version="7.0.0-$custom_abi.1+bbrv3"
release_tag="ubuntu-26.04-bbrv3-$source_version-abi$custom_abi"

emit source_version "$source_version"
emit source_tag "$source_tag"
emit vendor_abi "$vendor_abi"
emit custom_abi "$custom_abi"
emit kernel_release "$kernel_release"
emit package_version "$package_version"
emit release_tag "$release_tag"
