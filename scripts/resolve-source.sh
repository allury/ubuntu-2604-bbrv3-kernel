#!/usr/bin/env bash
set -euo pipefail

requested_version="${1:-auto}"
# p1 omitted the matching external ZFS package. p2 keeps Ubuntu's dependency,
# builds the real OpenZFS modules, and uses a new bootable ABI.
readonly patch_revision=2

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

emit() {
  local key="$1"
  local value="$2"

  # Keep the resolver usable from command substitution and its behavior tests,
  # even though GitHub exposes GITHUB_OUTPUT to every workflow step.
  printf '%s=%s\n' "$key" "$value"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
  fi
}

validate_ubuntu_archive_policy() {
  local source_file="${UBUNTU_SOURCES_FILE:-/etc/apt/sources.list.d/ubuntu.sources}"
  local source_entries
  local uri
  local suite
  local seen_resolute=false
  local seen_updates=false
  local seen_security=false

  [[ -f "$source_file" ]] ||
    die "Expected Ubuntu archive source configuration at $source_file."

  # The resolver runs in a clean ubuntu:26.04 image. Refuse an accidental
  # proposed, backports, PPA, or a different Ubuntu suite rather than treating
  # its kernel as a released 26.04 generic kernel.
  source_entries="$(awk '
    BEGIN { RS=""; FS="\n" }
    {
      types = uris = suites = enabled = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^Types:[[:space:]]*/) { sub(/^Types:[[:space:]]*/, "", $i); types = $i }
        if ($i ~ /^URIs:[[:space:]]*/) { sub(/^URIs:[[:space:]]*/, "", $i); uris = $i }
        if ($i ~ /^Suites:[[:space:]]*/) { sub(/^Suites:[[:space:]]*/, "", $i); suites = $i }
        if ($i ~ /^Enabled:[[:space:]]*/) { sub(/^Enabled:[[:space:]]*/, "", $i); enabled = tolower($i) }
      }
      if (enabled == "no" || types !~ /(^|[[:space:]])deb([[:space:]]|$)/) next
      count_uri = split(uris, uri_values, /[[:space:]]+/)
      count_suite = split(suites, suite_values, /[[:space:]]+/)
      for (u = 1; u <= count_uri; u++)
        for (s = 1; s <= count_suite; s++)
          if (uri_values[u] != "" && suite_values[s] != "")
            print uri_values[u] "\t" suite_values[s]
    }
  ' "$source_file")"
  [[ -n "$source_entries" ]] || die "No enabled Ubuntu deb archive source was found."

  while IFS=$'\t' read -r uri suite; do
    [[ "$uri" =~ ^https?://(archive|security)\.ubuntu\.com/ubuntu/?$ ]] ||
      die "Unsupported APT archive URI: $uri"
    case "$suite" in
      resolute) seen_resolute=true ;;
      resolute-updates) seen_updates=true ;;
      resolute-security) seen_security=true ;;
      *) die "Unsupported APT suite: $suite (only resolute, updates, and security are allowed)" ;;
    esac
  done <<< "$source_entries"

  [[ "$seen_resolute" == true && "$seen_updates" == true && "$seen_security" == true ]] ||
    die "The resolver requires resolute, resolute-updates, and resolute-security."
}

source_version_from_linux_binary() {
  local package_name="$1"
  local package_metadata
  local source_version
  local source_name
  local binary_version

  package_metadata="$(apt-cache show --no-all-versions "$package_name")"
  [[ -n "$package_metadata" ]] || die "APT has no metadata for $package_name."
  source_name="$(awk '/^Source: / { print $2; exit }' <<<"$package_metadata")"
  binary_version="$(awk '/^Version: / { print $2; exit }' <<<"$package_metadata")"
  [[ "$source_name" == linux ]] ||
    die "$package_name is sourced from ${source_name:-an unknown source}, not linux."
  source_version="$(awk '
    /^Source: linux \(/ {
      value = $0
      sub(/^Source: linux \(/, "", value)
      sub(/\)$/, "", value)
      print value
      exit
    }
  ' <<<"$package_metadata")"
  [[ -n "$source_version" ]] || source_version="$binary_version"
  [[ "$source_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+\.[0-9]+(\.[0-9]+)*$ ]] ||
    die "Could not obtain a valid linux source version from $package_name."
  [[ "$binary_version" == "$source_version" ]] ||
    die "$package_name has binary version $binary_version, not source version $source_version."
  printf '%s\n' "$source_version"
}

latest_released_resolute_linux_version() {
  local image_package
  local unsigned_image_package
  local source_version

  command -v apt-cache >/dev/null ||
    die "Automatic resolution requires apt-cache from an Ubuntu 26.04 environment."

  validate_ubuntu_archive_policy
  apt-cache policy >&2

  # Resolve the supported Ubuntu kernel from released APT metadata rather than
  # choosing the newest Launchpad Git tag, which may be unreleased.
  image_package="$(
    apt-cache depends linux-image-generic 2>/dev/null |
      awk '$1 == "Depends:" && $2 ~ /^linux-image-[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-generic$/ { print $2; exit }'
  )"
  [[ -n "$image_package" ]] ||
    die "Could not resolve the linux-image-generic dependency from APT metadata."

  # A signed image may be sourced from linux-signed. Cross-check the matching
  # unsigned image, which must name the actual linux source package used here.
  unsigned_image_package="linux-image-unsigned-${image_package#linux-image-}"
  source_version="$(source_version_from_linux_binary "$unsigned_image_package")"
  printf '%s\n' "$source_version"
}

if [[ "$requested_version" == "auto" ]]; then
  source_version="$(latest_released_resolute_linux_version)"
else
  source_version="$requested_version"
fi

if [[ "$source_version" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-([0-9]+)\.([0-9]+(\.[0-9]+)*)$ ]]; then
  upstream_version="${BASH_REMATCH[1]}"
  vendor_abi="${BASH_REMATCH[2]}"
  vendor_upload="${BASH_REMATCH[3]}"
else
  die "Expected an Ubuntu linux source version such as 7.0.0-30.30; got '$source_version'."
fi

if [[ "$requested_version" != auto ]]; then
  command -v apt-cache >/dev/null ||
    die 'Manual resolution requires apt-cache from an Ubuntu 26.04 environment.'
  validate_ubuntu_archive_policy
  apt-cache policy >&2
  manual_image="linux-image-unsigned-$upstream_version-$vendor_abi-generic"
  released_source_version="$(source_version_from_linux_binary "$manual_image")"
  [[ "$released_source_version" == "$source_version" ]] ||
    die "$source_version is not the released Ubuntu source behind $manual_image (found $released_source_version)."
fi

# Keep custom packages separate from Canonical's ABI namespace and make every
# patch revision bootable alongside its predecessor. For example, source
# 7.0.0-30.30 p2 produces 7.0.0-13002-generic.
custom_abi="$((10000 + 10#$vendor_abi * 100 + 10#$patch_revision))"
source_tag="Ubuntu-$source_version"
kernel_release="$upstream_version-$custom_abi-generic"
package_version="$upstream_version-$custom_abi.$vendor_upload+bbrv3.$patch_revision"
release_tag="ubuntu-26.04-bbrv3-$source_version-p$patch_revision"

emit source_version "$source_version"
emit source_tag "$source_tag"
emit upstream_version "$upstream_version"
emit vendor_abi "$vendor_abi"
emit vendor_upload "$vendor_upload"
emit custom_abi "$custom_abi"
emit kernel_release "$kernel_release"
emit package_version "$package_version"
emit patch_revision "$patch_revision"
emit release_tag "$release_tag"
