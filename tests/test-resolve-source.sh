#!/usr/bin/env bash
set -euo pipefail
trap 'printf "ERROR: resolver behavior test failed at line %s.\n" "$LINENO" >&2' ERR
unset GITHUB_OUTPUT

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/bin"

cat > "$test_root/bin/apt-cache" <<'FAKE_APT_CACHE'
#!/usr/bin/env bash
set -euo pipefail
version="${FAKE_VERSION:-7.0.0-31.31}"
source_name="${FAKE_SOURCE_NAME:-linux}"
if [[ "$version" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-([0-9]+)\. ]]; then
  image_release="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"
else
  exit 2
fi
case "${1:-}" in
  depends)
    printf 'linux-image-generic\n  Depends: linux-image-%s-generic\n' "$image_release"
    # Exceed the pipe buffer so a parser that exits early reliably makes this
    # producer fail with SIGPIPE when the caller enables pipefail.
    for ((i = 0; i < 12000; i++)); do
      printf '  Suggests: unrelated-package-%s\n' "$i"
    done
    ;;
  show)
    printf 'Package: linux-image-unsigned-%s-generic\n' "$image_release"
    printf 'Source: %s\n' "$source_name"
    printf 'Version: %s\n' "$version"
    ;;
  policy)
    printf 'Package files:\n 500 http://archive.ubuntu.com/ubuntu resolute-updates/main amd64 Packages\n'
    ;;
  *)
    exit 2
    ;;
esac
FAKE_APT_CACHE
chmod +x "$test_root/bin/apt-cache"

cat > "$test_root/good.sources" <<'GOOD_SOURCES'
Types: deb
URIs: http://archive.ubuntu.com/ubuntu
Suites: resolute resolute-updates
Components: main

Types: deb
URIs: http://security.ubuntu.com/ubuntu
Suites: resolute-security
Components: main
GOOD_SOURCES

cat > "$test_root/proposed.sources" <<'PROPOSED_SOURCES'
Types: deb
URIs: http://archive.ubuntu.com/ubuntu
Suites: resolute resolute-updates resolute-proposed
Components: main

Types: deb
URIs: http://security.ubuntu.com/ubuntu
Suites: resolute-security
Components: main
PROPOSED_SOURCES

resolver=("$repo_root/scripts/resolve-source.sh")
test_path="$test_root/bin:$PATH"

output="$(env PATH="$test_path" UBUNTU_SOURCES_FILE="$test_root/good.sources" FAKE_VERSION=7.0.0-31.31 "${resolver[@]}" auto 2>/dev/null)"
grep -Fxq 'source_version=7.0.0-31.31' <<< "$output"
grep -Fxq 'kernel_release=7.0.0-13102-generic' <<< "$output"
grep -Fxq 'package_version=7.0.0-13102.31+bbrv3.2' <<< "$output"

actions_output="$test_root/github-output"
output="$(env PATH="$test_path" UBUNTU_SOURCES_FILE="$test_root/good.sources" \
  GITHUB_OUTPUT="$actions_output" FAKE_VERSION=7.0.0-31.31 "${resolver[@]}" auto 2>/dev/null)"
grep -Fxq 'source_version=7.0.0-31.31' <<< "$output"
grep -Fxq 'source_version=7.0.0-31.31' "$actions_output"

output="$(env PATH="$test_path" UBUNTU_SOURCES_FILE="$test_root/good.sources" FAKE_VERSION=7.1.0-5.5 "${resolver[@]}" 7.1.0-5.5 2>/dev/null)"
grep -Fxq 'kernel_release=7.1.0-10502-generic' <<< "$output"

if env PATH="$test_path" UBUNTU_SOURCES_FILE="$test_root/proposed.sources" "${resolver[@]}" auto >/dev/null 2>&1; then
  printf '%s\n' 'ERROR: proposed APT source was accepted.' >&2
  exit 1
fi
if env PATH="$test_path" UBUNTU_SOURCES_FILE="$test_root/good.sources" FAKE_SOURCE_NAME=linux-signed "${resolver[@]}" auto >/dev/null 2>&1; then
  printf '%s\n' 'ERROR: non-linux source package was accepted.' >&2
  exit 1
fi
if env PATH="$test_path" UBUNTU_SOURCES_FILE="$test_root/good.sources" "${resolver[@]}" '7.0.0-31.31;touch injected' >/dev/null 2>&1; then
  printf '%s\n' 'ERROR: malformed manual version was accepted.' >&2
  exit 1
fi
if env PATH="$test_path" UBUNTU_SOURCES_FILE="$test_root/good.sources" FAKE_VERSION=7.0.0-31.32 "${resolver[@]}" 7.0.0-31.31 >/dev/null 2>&1; then
  printf '%s\n' 'ERROR: unreleased manual source version was accepted.' >&2
  exit 1
fi

printf '%s\n' 'Resolver behavior tests passed.'
