#!/usr/bin/env bash
set -euo pipefail

source_version="${1:?Usage: apply-bbrv3.sh <Ubuntu source version>}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
exact_patch="$repo_root/patches/bbrv3-ubuntu-$source_version.patch"
baseline_patch="$repo_root/patches/bbrv3-ubuntu-7.0.0-30.30.patch"
approved_sums="$repo_root/patches/APPROVED-SHA256SUMS"
# A rejected patch file is a repository problem, not a kernel that needs a new
# port. The workflow uses this status to avoid opening a porting issue.
readonly patch_file_rejected=3

reject_patch_file() {
  printf 'ERROR: %s\n' "$*" >&2
  exit "$patch_file_rejected"
}

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

patch_basename="$(basename "$patch_file")"
patch_sha256="$(sha256sum "$patch_file" | awk '{print $1}')"

# Only the exact bytes a maintainer reviewed may reach the kernel tree. The
# approval list uses sha256sum format and changes together with a reviewed
# patch, never on its own to make a build pass.
[[ -f "$approved_sums" ]] || reject_patch_file "Missing approved patch list: $approved_sums"
mapfile -t approved_sha256 < <(
  awk -v target="$patch_basename" '{ name = $2; sub(/^\*/, "", name) } name == target { print $1 }' \
    "$approved_sums"
)
(( ${#approved_sha256[@]} == 1 )) ||
  reject_patch_file "$patch_basename needs exactly one entry in patches/APPROVED-SHA256SUMS; found ${#approved_sha256[@]}."
[[ "$patch_sha256" == "${approved_sha256[0]}" ]] ||
  reject_patch_file "$patch_basename has SHA-256 $patch_sha256, but the approved value is ${approved_sha256[0]}."

# CRLF changes the patch context and can make a valid kernel patch fail on
# Linux.  Reject it instead of silently transforming source code in CI.
# -U keeps carriage returns on Windows builds of grep; Linux ignores it.
if LC_ALL=C grep -Uq $'\r' "$patch_file"; then
  reject_patch_file "Patch $patch_file contains CRLF line endings."
fi

printf 'Checking %s BBRv3 patch: %s (approved SHA-256 %s)\n' "$patch_kind" "$patch_file" "$patch_sha256"
git apply --check --whitespace=error "$patch_file"
git apply --whitespace=error "$patch_file"

grep -Eq '^#define BBR_VERSION[[:space:]]+3$' net/ipv4/tcp_bbr.c ||
  { printf 'ERROR: BBRv3 marker was not found after patching.\n' >&2; exit 1; }

if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'BBRV3_PATCH_FILE=%s\n' "$patch_basename" >> "$GITHUB_ENV"
  printf 'BBRV3_PATCH_SHA256=%s\n' "$patch_sha256" >> "$GITHUB_ENV"
fi

printf 'Applied BBRv3 patch successfully: %s (%s)\n' "$patch_basename" "$patch_sha256"
