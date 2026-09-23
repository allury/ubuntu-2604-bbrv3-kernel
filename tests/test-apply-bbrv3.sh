#!/usr/bin/env bash
set -euo pipefail
trap 'printf "ERROR: patch application test failed at line %s.\n" "$LINENO" >&2' ERR
unset GITHUB_ENV

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

patch_name=bbrv3-ubuntu-7.0.0-30.30.patch
good_patch="$test_root/$patch_name"
cat > "$good_patch" <<'PATCH'
diff --git a/net/ipv4/tcp_bbr.c b/net/ipv4/tcp_bbr.c
--- a/net/ipv4/tcp_bbr.c
+++ b/net/ipv4/tcp_bbr.c
@@ -1,2 +1,3 @@
 /* BBR congestion control */
+#define BBR_VERSION 3
 int bbr;
PATCH

# A copy of the repository layout with its own patch and approval list. The
# script under test resolves both relative to its own location.
new_repo() {
  local repo="$test_root/repo-$1"
  local patch_source="$2"
  local approved_source="$3"
  mkdir -p "$repo/scripts" "$repo/patches"
  cp -- "$repo_root/scripts/apply-bbrv3.sh" "$repo/scripts/apply-bbrv3.sh"
  cp -- "$patch_source" "$repo/patches/$patch_name"
  if [[ -n "$approved_source" ]]; then
    cp -- "$approved_source" "$repo/patches/APPROVED-SHA256SUMS"
  fi
  printf '%s\n' "$repo"
}

new_tree() {
  local tree="$test_root/tree-$1"
  mkdir -p "$tree/net/ipv4"
  printf '/* BBR congestion control */\nint bbr;\n' > "$tree/net/ipv4/tcp_bbr.c"
  git -C "$tree" init -q
  printf '%s\n' "$tree"
}

apply_status() {
  local repo="$1"
  local tree="$2"
  local version="$3"
  local status=0
  (cd "$tree" && bash "$repo/scripts/apply-bbrv3.sh" "$version") >/dev/null 2>&1 || status=$?
  printf '%s\n' "$status"
}

needs_port() {
  [[ "$1" != 0 && "$1" != 3 ]]
}

untouched() {
  ! grep -Fq 'BBR_VERSION' "$1/net/ipv4/tcp_bbr.c"
}

good_sha256="$(sha256sum "$good_patch" | awk '{print $1}')"
printf '%s  %s\n' "$good_sha256" "$patch_name" > "$test_root/approved"

# An approved patch applies and is recorded for later workflow steps.
repo="$(new_repo approved "$good_patch" "$test_root/approved")"
tree="$(new_tree approved)"
(cd "$tree" && GITHUB_ENV="$test_root/github-env" bash "$repo/scripts/apply-bbrv3.sh" 7.0.0-30.30 >/dev/null)
grep -Fxq '#define BBR_VERSION 3' "$tree/net/ipv4/tcp_bbr.c"
grep -Fxq "BBRV3_PATCH_FILE=$patch_name" "$test_root/github-env"
grep -Fxq "BBRV3_PATCH_SHA256=$good_sha256" "$test_root/github-env"

# Later 7.0 sources fall back to the reviewed baseline patch.
tree="$(new_tree fallback)"
[[ "$(apply_status "$repo" "$tree" 7.0.0-34.34)" == 0 ]]

# sha256sum's binary-mode marker, as written on some platforms, is accepted.
printf '%s *%s\n' "$good_sha256" "$patch_name" > "$test_root/approved-binary"
repo="$(new_repo binary-marker "$good_patch" "$test_root/approved-binary")"
tree="$(new_tree binary-marker)"
[[ "$(apply_status "$repo" "$tree" 7.0.0-30.30)" == 0 ]]

# Changed patch bytes are rejected before the tree is touched.
cp -- "$good_patch" "$test_root/changed.patch"
printf '%s\n' '-- ' >> "$test_root/changed.patch"
repo="$(new_repo changed "$test_root/changed.patch" "$test_root/approved")"
tree="$(new_tree changed)"
[[ "$(apply_status "$repo" "$tree" 7.0.0-30.30)" == 3 ]]
untouched "$tree"

# A missing list, a missing entry and duplicate entries are all rejected.
repo="$(new_repo no-list "$good_patch" '')"
tree="$(new_tree no-list)"
[[ "$(apply_status "$repo" "$tree" 7.0.0-30.30)" == 3 ]]
untouched "$tree"

printf '%s  %s\n' "$good_sha256" other.patch > "$test_root/approved-other"
repo="$(new_repo no-entry "$good_patch" "$test_root/approved-other")"
tree="$(new_tree no-entry)"
[[ "$(apply_status "$repo" "$tree" 7.0.0-30.30)" == 3 ]]
untouched "$tree"

cat "$test_root/approved" "$test_root/approved" > "$test_root/approved-twice"
repo="$(new_repo duplicate "$good_patch" "$test_root/approved-twice")"
tree="$(new_tree duplicate)"
[[ "$(apply_status "$repo" "$tree" 7.0.0-30.30)" == 3 ]]
untouched "$tree"

# CRLF is rejected even when its bytes were approved.
sed 's/$/\r/' "$good_patch" > "$test_root/crlf.patch"
printf '%s  %s\n' "$(sha256sum "$test_root/crlf.patch" | awk '{print $1}')" "$patch_name" > "$test_root/approved-crlf"
repo="$(new_repo crlf "$test_root/crlf.patch" "$test_root/approved-crlf")"
tree="$(new_tree crlf)"
[[ "$(apply_status "$repo" "$tree" 7.0.0-30.30)" == 3 ]]
untouched "$tree"

# An approved patch that no longer matches the source needs a port instead.
repo="$(new_repo stale-context "$good_patch" "$test_root/approved")"
tree="$(new_tree stale-context)"
printf '/* BBR congestion control, reworked */\nint bbr;\n' > "$tree/net/ipv4/tcp_bbr.c"
needs_port "$(apply_status "$repo" "$tree" 7.0.0-34.34)"

# So does a kernel series without any patch.
tree="$(new_tree new-series)"
needs_port "$(apply_status "$repo" "$tree" 7.1.0-5.5)"
untouched "$tree"

printf '%s\n' 'Patch application tests passed.'
