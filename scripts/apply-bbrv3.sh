#!/usr/bin/env bash
set -euo pipefail

source_version="${1:?Usage: apply-bbrv3.sh <Ubuntu source version>}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
exact_patch="$repo_root/patches/bbrv3-ubuntu-$source_version.patch"
baseline_patch="$repo_root/patches/bbrv3-ubuntu-7.0.0-30.30.patch"

if [[ -f "$exact_patch" ]]; then
  patch_file="$exact_patch"
  patch_kind="version-specific"
elif [[ "$source_version" == 7.0.0-* && -f "$baseline_patch" ]]; then
  patch_file="$baseline_patch"
  patch_kind="7.0 baseline"
else
  printf 'ERROR: No BBRv3 patch is available for Ubuntu source %s. Add a version-specific patch before building this kernel series.\n' "$source_version" >&2
  exit 1
fi

# CRLF changes the patch context and can make a valid kernel patch fail on
# Linux.  Reject it instead of silently transforming source code in CI.
if LC_ALL=C grep -q $'\r' "$patch_file"; then
  printf 'ERROR: Patch %s contains CRLF line endings.\n' "$patch_file" >&2
  exit 1
fi

printf 'Checking %s BBRv3 patch: %s\n' "$patch_kind" "$patch_file"
git apply --check --whitespace=error "$patch_file"
git apply --whitespace=error "$patch_file"

grep -Eq '^#define BBR_VERSION[[:space:]]+3$' net/ipv4/tcp_bbr.c ||
  { printf 'ERROR: BBRv3 marker was not found after patching.\n' >&2; exit 1; }

patch_basename="$(basename "$patch_file")"
patch_sha256="$(sha256sum "$patch_file" | awk '{print $1}')"
if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'BBRV3_PATCH_FILE=%s\n' "$patch_basename" >> "$GITHUB_ENV"
  printf 'BBRV3_PATCH_SHA256=%s\n' "$patch_sha256" >> "$GITHUB_ENV"
fi

printf 'Applied BBRv3 patch successfully: %s (%s)\n' "$patch_basename" "$patch_sha256"
