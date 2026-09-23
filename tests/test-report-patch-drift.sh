#!/usr/bin/env bash
set -euo pipefail
trap 'printf "ERROR: patch drift report test failed at line %s.\n" "$LINENO" >&2' ERR

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
report_drift=("$repo_root/scripts/report-patch-drift.sh")

# A failing command negated with ! never trips errexit, but a failing function does.
absent() {
  ! grep "$@"
}

# An upstream with annotated release tags, like the Ubuntu kernel repository.
upstream="$test_root/upstream"
git init -q -b main "$upstream"
mkdir -p "$upstream/net/ipv4"
release() {
  git -C "$upstream" add -A
  git -C "$upstream" commit -q -m "$1"
  git -C "$upstream" tag -a "$1" -m "$1"
}
printf 'int bbr;\n' > "$upstream/net/ipv4/tcp_bbr.c"
printf 'int input;\nint unchanged;\n' > "$upstream/net/ipv4/tcp_input.c"
printf 'unrelated\n' > "$upstream/README"
release Ubuntu-7.0.0-30.30
printf 'still unrelated\n' > "$upstream/README"
release Ubuntu-7.0.0-31.31
printf 'int input;\nint changed;\n' > "$upstream/net/ipv4/tcp_input.c"
release Ubuntu-7.0.0-34.34

patch="$test_root/bbrv3-ubuntu-7.0.0-30.30.patch"
cat > "$patch" <<'PATCH'
diff --git a/net/ipv4/tcp_bbr.c b/net/ipv4/tcp_bbr.c
--- a/net/ipv4/tcp_bbr.c
+++ b/net/ipv4/tcp_bbr.c
@@ -1 +1,2 @@
+#define BBR_VERSION 3
 int bbr;
diff --git a/net/ipv4/tcp_input.c b/net/ipv4/tcp_input.c
--- a/net/ipv4/tcp_input.c
+++ b/net/ipv4/tcp_input.c
@@ -1,2 +1,3 @@
 int input;
+int bbr_input;
 int unchanged;
PATCH

checkout() {
  local tree="$test_root/kernel-$1"
  git clone -q --no-local --depth=1 --branch "Ubuntu-$1" "$upstream" "$tree" 2>/dev/null
  printf '%s\n' "$tree"
}

# Ubuntu changed a patched file: the report names it and carries the diff.
tree="$(checkout 7.0.0-34.34)"
"${report_drift[@]}" "$tree" "$patch" "$test_root/report-34" >/dev/null
grep -Fxq 'Patch: bbrv3-ubuntu-7.0.0-30.30.patch' "$test_root/report-34"
grep -Fxq 'Review baseline: Ubuntu-7.0.0-30.30' "$test_root/report-34"
grep -Fxq 'Built source: Ubuntu-7.0.0-34.34' "$test_root/report-34"
grep -Fxq 'Patched files: 2' "$test_root/report-34"
grep -Fxq 'Changed since baseline: 1' "$test_root/report-34"
grep -Fxq 'Lines added: 1' "$test_root/report-34"
grep -Fxq 'Lines removed: 1' "$test_root/report-34"
grep -Fxq -- '-int unchanged;' "$test_root/report-34"
grep -Fxq '+int changed;' "$test_root/report-34"
absent -Fq unrelated "$test_root/report-34"

# Ubuntu changed only files outside the patch.
tree="$(checkout 7.0.0-31.31)"
"${report_drift[@]}" "$tree" "$patch" "$test_root/report-31" >/dev/null
grep -Fxq 'Changed since baseline: 0' "$test_root/report-31"
grep -Fxq 'Lines added: 0' "$test_root/report-31"
absent -q "^diff --git " "$test_root/report-31"

# Building the reviewed baseline itself needs no second tag.
tree="$(checkout 7.0.0-30.30)"
"${report_drift[@]}" "$tree" "$patch" "$test_root/report-30" >/dev/null
grep -Fxq 'Changed since baseline: 0' "$test_root/report-30"
[[ -z "$(git -C "$tree" tag --list 'Ubuntu-7.0.0-3[14].*')" ]]

# The baseline comes from the patch name, and renames are not guessed at.
cp -- "$patch" "$test_root/bbrv3-custom.patch"
if "${report_drift[@]}" "$tree" "$test_root/bbrv3-custom.patch" "$test_root/report-bad" >/dev/null 2>&1; then
  printf '%s\n' 'ERROR: a patch without a source version in its name was accepted.' >&2
  exit 1
fi
renamed="$test_root/rename/bbrv3-ubuntu-7.0.0-30.30.patch"
mkdir -p "$(dirname -- "$renamed")"
printf 'diff --git a/net/ipv4/tcp_bbr.c b/net/ipv4/tcp_bbr2.c\nrename from net/ipv4/tcp_bbr.c\nrename to net/ipv4/tcp_bbr2.c\n' > "$renamed"
if "${report_drift[@]}" "$tree" "$renamed" "$test_root/report-rename" >/dev/null 2>&1; then
  printf '%s\n' 'ERROR: a renaming patch was accepted.' >&2
  exit 1
fi

printf '%s\n' 'Patch drift report tests passed.'
