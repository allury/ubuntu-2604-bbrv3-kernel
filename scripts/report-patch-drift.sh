#!/usr/bin/env bash
# Report how Ubuntu changed the files a BBRv3 patch touches since the Ubuntu
# source tag the patch was reviewed against. An exact `git apply` only proves
# that the hunk context still matches; code outside that context may have
# changed underneath the patch and needs human review.
set -euo pipefail

usage='Usage: report-patch-drift.sh <kernel-git-tree> <patch-file> <report-file>'
kernel_tree="${1:?$usage}"
patch_file="${2:?$usage}"
report_file="${3:?$usage}"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

# Pathspecs below are file names taken from the patch, never patterns.
export GIT_LITERAL_PATHSPECS=1

patch_name="$(basename -- "$patch_file")"
[[ "$patch_name" =~ ^bbrv3-ubuntu-([0-9]+\.[0-9]+\.[0-9]+-[0-9]+\.[0-9]+(\.[0-9]+)*)\.patch$ ]] ||
  die "Cannot derive the reviewed Ubuntu source from $patch_name."
baseline_tag="Ubuntu-${BASH_REMATCH[1]}"

mapfile -t patched_paths < <(sed -n 's|^diff --git a/\([^ ]*\) b/\1$|\1|p' "$patch_file")
header_count="$(grep -c '^diff --git ' "$patch_file" || true)"
(( ${#patched_paths[@]} > 0 )) || die "$patch_name contains no file headers."
(( ${#patched_paths[@]} == header_count )) ||
  die "$patch_name renames files or uses paths this report cannot compare."

source_tag="$(git -C "$kernel_tree" describe --exact-match --tags HEAD)"
source_commit="$(git -C "$kernel_tree" rev-parse --verify 'HEAD^{commit}')"
if [[ "$source_tag" == "$baseline_tag" ]]; then
  baseline_commit="$source_commit"
else
  git -C "$kernel_tree" fetch --quiet --depth=1 --no-tags origin \
    "+refs/tags/$baseline_tag:refs/tags/$baseline_tag"
  baseline_commit="$(git -C "$kernel_tree" rev-parse --verify "refs/tags/$baseline_tag^{commit}")"
fi

diff_range=("$baseline_commit" "$source_commit" -- "${patched_paths[@]}")
mapfile -t changed_paths < <(git -C "$kernel_tree" diff --name-only "${diff_range[@]}")
read -r lines_added lines_removed < <(
  git -C "$kernel_tree" diff --numstat "${diff_range[@]}" |
    awk '{ added += $1; removed += $2 } END { printf "%d %d\n", added, removed }'
)

mkdir -p -- "$(dirname -- "$report_file")"
{
  printf 'Patch: %s\n' "$patch_name"
  printf 'Review baseline: %s\n' "$baseline_tag"
  printf 'Review baseline commit: %s\n' "$baseline_commit"
  printf 'Built source: %s\n' "$source_tag"
  printf 'Built source commit: %s\n' "$source_commit"
  printf 'Patched files: %d\n' "${#patched_paths[@]}"
  printf 'Changed since baseline: %d\n' "${#changed_paths[@]}"
  printf 'Lines added: %d\n' "$lines_added"
  printf 'Lines removed: %d\n' "$lines_removed"
  printf '\n'
  printf '%s\n' 'Ubuntu changes to the files touched by the patch, from the review baseline to the built source.'
  printf '%s\n' 'The patch still applying exactly does not show that these changes are compatible with BBRv3.'
  if (( ${#changed_paths[@]} > 0 )); then
    printf '\n'
    git -C "$kernel_tree" diff --no-color --no-ext-diff --stat=200 "${diff_range[@]}"
    printf '\n'
    git -C "$kernel_tree" diff --no-color --no-ext-diff "${diff_range[@]}"
  fi
} > "$report_file"

sed '/^$/q' "$report_file"
