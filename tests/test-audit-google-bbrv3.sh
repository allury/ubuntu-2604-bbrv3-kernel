#!/usr/bin/env bash
set -euo pipefail
trap 'printf "ERROR: Google BBRv3 audit test failed at line %s.\n" "$LINENO" >&2' ERR

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
audit=("$repo_root/scripts/audit-google-bbrv3.sh")

# A failing command negated with ! never trips errexit, but a failing function does.
absent() {
  ! grep "$@"
}

# file:// URL of a local repository; Git for Windows needs a drive letter.
url_of() {
  if command -v cygpath >/dev/null; then
    printf 'file:///%s\n' "$(cygpath -m "$1")"
  else
    printf 'file://%s\n' "$1"
  fi
}

commit_all() {
  git -C "$1" add -A
  git -C "$1" commit -q -m "$2"
}

# The Linux release Google's branch is based on.
linux="$test_root/linux"
git init -q -b main "$linux"
mkdir -p "$linux/net/ipv4" "$linux/include/net"
printf '%s\n' '/* BBR v1 */' 'static int bbr_version = 1;' 'static int bbr_gain = 2885;' \
  > "$linux/net/ipv4/tcp_bbr.c"
printf '%s\n' 'void tcp_write(void)' '{' '	send();' '}' > "$linux/net/ipv4/tcp_output.c"
printf '%s\n' 'void tcp_rate_gen(void)' '{' '	sample();' '}' > "$linux/net/ipv4/tcp_rate.c"
printf '%s\n' 'struct tcp_sock;' > "$linux/include/net/tcp.h"
commit_all "$linux" 'Linux 6.13.7'
git -C "$linux" tag -a v6.13.7 -m 'Linux 6.13.7'
base_commit="$(git -C "$linux" rev-parse 'v6.13.7^{commit}')"

# Google's branch: that release plus two commits, tagged like Google's releases.
google="$test_root/google"
git clone -q "$linux" "$google"
git -C "$google" config uploadpack.allowReachableSHA1InWant true
printf '%s\n' '/* BBR v3 */' 'static int bbr_version = 3;' 'static int bbr_gain = 2770;' \
  'static bool bbr_ecn_low(struct sock *sk) { return tcp_sk(sk)->ecn_flags & TCP_ECN_OK; }' \
  > "$google/net/ipv4/tcp_bbr.c"
printf '%s\n' 'void tcp_write(void)' '{' '	tcp_set_tx_in_flight(sk, skb);' '	send();' \
  '	tcp_ecn_low_on_syn(sk, skb);' '}' > "$google/net/ipv4/tcp_output.c"
printf '%s\n' 'void tcp_rate_gen(void)' '{' '	sample();' '	rs->tx_in_flight = scb->tx.in_flight;' '}' \
  > "$google/net/ipv4/tcp_rate.c"
printf '%s\n' 'struct tcp_sock;' '#define TCP_ECN_LOW 16' > "$google/include/net/tcp.h"
commit_all "$google" 'net-tcp_bbr: v3: update TCP "bbr" congestion control module to BBRv3'
cp "$linux/net/ipv4/tcp_bbr.c" "$google/net/ipv4/tcp_bbr1.c"
mkdir -p "$google/gtests"
printf '%s\n' '#!/bin/sh' 'echo test' > "$google/gtests/run.sh"
commit_all "$google" 'net-test: a copy of BBRv1 and test scripts'
git -C "$google" tag bbrv3-2025-03-18
google_commit="$(git -C "$google" rev-parse HEAD)"

# Ubuntu's source: Linux moved on, so the rate code and the ECN helper live
# elsewhere, and tcp_bbr.c gained a fix.
ubuntu="$test_root/ubuntu"
git init -q -b main "$ubuntu"
mkdir -p "$ubuntu/net/ipv4" "$ubuntu/include/net"
printf '%s\n' '/* BBR v1 */' 'static int bbr_version = 1;' 'static int bbr_gain = 2885;' \
  'static int bbr_upstream_fix = 1;' > "$ubuntu/net/ipv4/tcp_bbr.c"
printf '%s\n' 'void tcp_write(void)' '{' '	prepare();' '	send();' '}' > "$ubuntu/net/ipv4/tcp_output.c"
printf '%s\n' 'void tcp_rate_gen(void)' '{' '	sample();' '}' > "$ubuntu/net/ipv4/tcp_input.c"
printf '%s\n' 'static inline void tcp_ecn_send_syn(void)' '{' '}' > "$ubuntu/include/net/tcp_ecn.h"
printf '%s\n' 'struct tcp_sock;' > "$ubuntu/include/net/tcp.h"
commit_all "$ubuntu" 'Ubuntu-7.0.0-30.30'
git -C "$ubuntu" tag -a Ubuntu-7.0.0-30.30 -m 'Ubuntu-7.0.0-30.30'

# The port: Google's change, moved where Linux moved the code, plus one
# adaptation of its own.
port="$test_root/port"
git clone -q "$ubuntu" "$port"
printf '%s\n' '/* BBR v3 */' 'static int bbr_version = 3;' 'static int bbr_gain = 2770;' \
  'static bool bbr_ecn_low(struct sock *sk) { return tcp_ecn_mode_any(tcp_sk(sk)); }' \
  'static int bbr_upstream_fix = 1;' > "$port/net/ipv4/tcp_bbr.c"
printf '%s\n' 'void tcp_write(void)' '{' '	prepare();' '	tcp_set_tx_in_flight(sk, skb);' '	send();' \
  '	tcp_port_only_adaptation(sk);' '}' > "$port/net/ipv4/tcp_output.c"
printf '%s\n' 'void tcp_rate_gen(void)' '{' '	sample();' '	rs->tx_in_flight = scb->tx.in_flight;' '}' \
  > "$port/net/ipv4/tcp_input.c"
printf '%s\n' 'static inline void tcp_ecn_send_syn(void)' '{' '	tcp_ecn_low_on_syn(sk, skb);' '}' \
  > "$port/include/net/tcp_ecn.h"
printf '%s\n' 'struct tcp_sock;' '#define TCP_ECN_LOW BIT(5)' > "$port/include/net/tcp.h"
mkdir -p "$test_root/patches"
patch="$test_root/patches/bbrv3-ubuntu-7.0.0-30.30.patch"
git -C "$port" diff > "$patch"

reference="$test_root/GOOGLE-REFERENCE"
write_reference() {
  cat > "$reference" <<EOF
# Test reference.
google-repository $(url_of "$google")
google-tag bbrv3-2025-03-18
google-commit $google_commit
base-repository $(url_of "$linux")
base-tag v6.13.7
base-commit $base_commit
google-commits ${1:-2}
whole-file net/ipv4/tcp_bbr.c
EOF
}
write_reference
UBUNTU_KERNEL_REPOSITORY="$(url_of "$ubuntu")"
export UBUNTU_KERNEL_REPOSITORY

report="$test_root/report.txt"
"${audit[@]}" "$reference" "$patch" "$test_root/git" "$report" >/dev/null

# Provenance.
grep -Fxq 'Patch: bbrv3-ubuntu-7.0.0-30.30.patch' "$report"
grep -Fxq "Patch SHA-256: $(sha256sum "$patch" | cut -d' ' -f1)" "$report"
grep -Fxq "Google reference: bbrv3-2025-03-18 $google_commit" "$report"
grep -Fxq "Google base: v6.13.7 $base_commit, 2 commits below the reference" "$report"
grep -Fq "${google_commit:0:12} net-test: a copy of BBRv1 and test scripts" "$report"
grep -Fxq 'Files changed: 6 by Google, 5 by the port' "$report"

# Lines Linux moved elsewhere are paired across files; the rest are listed.
grep -Fxq 'Files compared line by line: 5' "$report"
grep -Fxq 'net/ipv4/tcp_output.c (Google) -> include/net/tcp_ecn.h (port): +1 -0' "$report"
grep -Fxq 'net/ipv4/tcp_rate.c (Google) -> net/ipv4/tcp_input.c (port): +1 -0' "$report"
grep -Fxq "Lines only in Google's change: +1 -0" "$report"
grep -Fxq 'Lines only in the port: +2 -0' "$report"
grep -Fxq '    +#define TCP_ECN_LOW 16' "$report"
grep -Fxq '    +#define TCP_ECN_LOW BIT(5)' "$report"
grep -Fxq '    +	tcp_port_only_adaptation(sk);' "$report"
absent -Fxq '    +	tcp_set_tx_in_flight(sk, skb);' "$report"
grep -Eq '^net/ipv4/tcp_bbr1\.c +\+3 -0 +- +- +- +created by Google, not in the port$' "$report"
grep -Eq '^gtests/run\.sh +\+2 -0 +- .*created by Google, not in the port$' "$report"

# The replaced file is compared whole, with the Linux fix it had to keep.
grep -Fxq 'Whole file net/ipv4/tcp_bbr.c, port against Google: +2 -1' "$report"
grep -Fxq -- '-static bool bbr_ecn_low(struct sock *sk) { return tcp_sk(sk)->ecn_flags & TCP_ECN_OK; }' "$report"
grep -Fxq '+static bool bbr_ecn_low(struct sock *sk) { return tcp_ecn_mode_any(tcp_sk(sk)); }' "$report"
grep -Fxq '+static int bbr_upstream_fix = 1;' "$report"

# The same inputs give the same bytes, from a reused or a fresh Git directory.
"${audit[@]}" "$reference" "$patch" "$test_root/git" "$test_root/again.txt" >/dev/null
cmp -s "$report" "$test_root/again.txt"
"${audit[@]}" "$reference" "$patch" "$test_root/git-fresh" "$test_root/fresh.txt" >/dev/null
cmp -s "$report" "$test_root/fresh.txt"

expect_failure() {
  local message="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'ERROR: %s\n' "$message" >&2
    exit 1
  fi
}

# The reference must describe Google's branch exactly.
write_reference 3
expect_failure 'a wrong commit count was accepted.' \
  "${audit[@]}" "$reference" "$patch" "$test_root/git" "$test_root/bad.txt"
write_reference
printf 'google-branch v3\n' >> "$reference"
expect_failure 'an unknown reference key was accepted.' \
  "${audit[@]}" "$reference" "$patch" "$test_root/git" "$test_root/bad.txt"

# A moved Google tag is reported, not followed.
write_reference
git -C "$google" tag -f bbrv3-2025-03-18 HEAD~1 >/dev/null
expect_failure 'a moved Google tag was accepted.' \
  "${audit[@]}" "$reference" "$patch" "$test_root/git" "$test_root/bad.txt"
git -C "$google" tag -f bbrv3-2025-03-18 "$google_commit" >/dev/null

# The Ubuntu source comes from the patch name.
cp "$patch" "$test_root/patches/bbrv3-custom.patch"
expect_failure 'a patch without a source version in its name was accepted.' \
  "${audit[@]}" "$reference" "$test_root/patches/bbrv3-custom.patch" "$test_root/git" "$test_root/bad.txt"

printf '%s\n' 'Google BBRv3 audit tests passed.'
