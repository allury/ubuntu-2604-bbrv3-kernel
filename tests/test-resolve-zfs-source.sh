#!/usr/bin/env bash
set -euo pipefail
trap 'printf "ERROR: ZFS source resolver test failed at line %s.\n" "$LINENO" >&2' ERR

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/bin"

cat > "$test_root/bin/apt-cache" <<'FAKE_APT_CACHE'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  policy)
    printf 'zfs-dkms:\n  Installed: (none)\n  Candidate: %s\n' "${FAKE_ZFS_VERSION:-2.4.1-1ubuntu3}"
    for ((i = 0; i < 12000; i++)); do
      printf '     unrelated-policy-line-%s\n' "$i"
    done
    ;;
  show)
    printf 'Package: zfs-dkms\n'
    printf 'Source: %s\n' "${FAKE_ZFS_SOURCE:-zfs-linux}"
    printf 'Version: %s\n' "${FAKE_ZFS_METADATA_VERSION:-${FAKE_ZFS_VERSION:-2.4.1-1ubuntu3}}"
    ;;
  *)
    exit 2
    ;;
esac
FAKE_APT_CACHE
chmod +x "$test_root/bin/apt-cache"

resolver=("$repo_root/scripts/resolve-zfs-source.sh")
test_path="$test_root/bin:$PATH"

output="$(env PATH="$test_path" FAKE_ZFS_VERSION=2.4.1-1ubuntu3 "${resolver[@]}" 2>/dev/null)"
grep -Fxq 'zfs_source_name=zfs-linux' <<<"$output"
grep -Fxq 'zfs_source_version=2.4.1-1ubuntu3' <<<"$output"

if env PATH="$test_path" FAKE_ZFS_VERSION='(none)' "${resolver[@]}" >/dev/null 2>&1; then
  printf '%s\n' 'ERROR: an unavailable zfs-dkms candidate was accepted.' >&2
  exit 1
fi
if env PATH="$test_path" FAKE_ZFS_SOURCE=untrusted-zfs "${resolver[@]}" >/dev/null 2>&1; then
  printf '%s\n' 'ERROR: an unexpected ZFS source package was accepted.' >&2
  exit 1
fi
if env PATH="$test_path" FAKE_ZFS_METADATA_VERSION=2.4.1-1ubuntu4 "${resolver[@]}" >/dev/null 2>&1; then
  printf '%s\n' 'ERROR: mismatched candidate and metadata versions were accepted.' >&2
  exit 1
fi

printf '%s\n' 'ZFS source resolver tests passed.'
