#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

command -v apt-cache >/dev/null || die 'Missing apt-cache.'

# Capture the complete producer output before parsing it. An early-exiting awk
# consumer would otherwise make apt-cache receive SIGPIPE under pipefail.
zfs_policy="$(apt-cache policy zfs-dkms)"
printf '%s\n' "$zfs_policy" >&2
mapfile -t zfs_candidates < <(
  awk '/^[[:space:]]*Candidate:/ { print $2 }' <<<"$zfs_policy"
)
(( ${#zfs_candidates[@]} == 1 )) ||
  die "Expected exactly one zfs-dkms candidate, found ${#zfs_candidates[@]}."
zfs_version="${zfs_candidates[0]}"
[[ -n "$zfs_version" && "$zfs_version" != '(none)' ]] ||
  die 'Ubuntu APT metadata has no zfs-dkms candidate.'

zfs_metadata="$(apt-cache show --no-all-versions zfs-dkms)"
[[ -n "$zfs_metadata" ]] || die 'APT returned no metadata for zfs-dkms.'
mapfile -t zfs_packages < <(awk '$1 == "Package:" { print $2 }' <<<"$zfs_metadata")
mapfile -t zfs_sources < <(awk '$1 == "Source:" { print $2 }' <<<"$zfs_metadata")
mapfile -t metadata_versions < <(awk '$1 == "Version:" { print $2 }' <<<"$zfs_metadata")
(( ${#zfs_packages[@]} == 1 )) ||
  die "Expected one zfs-dkms Package field, found ${#zfs_packages[@]}."
(( ${#zfs_sources[@]} == 1 )) ||
  die "Expected one zfs-dkms Source field, found ${#zfs_sources[@]}."
(( ${#metadata_versions[@]} == 1 )) ||
  die "Expected one zfs-dkms Version field, found ${#metadata_versions[@]}."
[[ "${zfs_packages[0]}" == zfs-dkms ]] ||
  die "APT returned unexpected binary package: ${zfs_packages[0]}"
[[ "${zfs_sources[0]}" == zfs-linux ]] ||
  die "zfs-dkms came from unexpected source: ${zfs_sources[0]}"
[[ "${metadata_versions[0]}" == "$zfs_version" ]] ||
  die "zfs-dkms metadata version ${metadata_versions[0]} does not match candidate $zfs_version."

printf 'zfs_source_name=%s\n' "${zfs_sources[0]}"
printf 'zfs_source_version=%s\n' "$zfs_version"
