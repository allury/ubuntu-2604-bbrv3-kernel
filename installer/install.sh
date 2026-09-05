#!/usr/bin/env bash
# Independently versioned installer v1.0.0, derived from stable p2.
# Download one stable GitHub Release, verify it, install it, and
# optionally reboot. The post-boot systemd service performs the runtime test.
set -euo pipefail

readonly repository='allury/ubuntu-2604-bbrv3-kernel'

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $EUID == 0 ]] || die 'Run with sudo.'
requested_tag='latest'
install_options=()
while (( $# > 0 )); do
  case "$1" in
    --tag)
      (( $# >= 2 )) || die '--tag requires a release tag.'
      requested_tag="$2"
      shift 2
      ;;
    --reboot)
      install_options+=(--reboot)
      shift
      ;;
    --allow-no-fallback)
      install_options+=(--allow-no-fallback)
      shift
      ;;
    -h|--help)
      printf 'Usage: %s [--tag ubuntu-26.04-bbrv3-VERSION-pN] [--reboot] [--allow-no-fallback]\n' "$0"
      exit 0
      ;;
    *) die "Unknown option: $1" ;;
  esac
done

if [[ "$requested_tag" != latest ]]; then
  [[ "$requested_tag" =~ ^ubuntu-26\.04-bbrv3-[0-9]+\.[0-9]+\.[0-9]+-[0-9]+\.[0-9]+(\.[0-9]+)*-p[1-9][0-9]*$ ]] ||
    die "Unexpected release tag: $requested_tag"
  api_url="https://api.github.com/repos/$repository/releases/tags/$requested_tag"
else
  api_url="https://api.github.com/repos/$repository/releases/latest"
fi

for tool in bash curl mktemp python3 sha256sum; do
  command -v "$tool" >/dev/null || die "Missing prerequisite: $tool"
done

download_dir="$(mktemp -d /var/tmp/ubuntu-bbrv3-release.XXXXXX)"
cleanup() {
  case "$download_dir" in
    /var/tmp/ubuntu-bbrv3-release.*) rm -rf -- "$download_dir" ;;
    *) printf 'Refusing to remove unexpected path: %s\n' "$download_dir" >&2 ;;
  esac
}
trap cleanup EXIT

curl --fail --location --silent --show-error \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  "$api_url" > "$download_dir/release.json"

python3 - "$download_dir/release.json" "$download_dir" "$repository" "$requested_tag" <<'PY'
import json
import os
import pathlib
import re
import sys
import urllib.parse
import urllib.request

metadata_path, output_path, repository, requested_tag = sys.argv[1:]
with open(metadata_path, encoding="utf-8") as stream:
    release = json.load(stream)

if release.get("draft") or release.get("prerelease"):
    raise SystemExit("ERROR: Refusing a draft or prerelease.")
tag = release.get("tag_name", "")
tag_pattern = r"ubuntu-26\.04-bbrv3-[0-9]+\.[0-9]+\.[0-9]+-[0-9]+\.[0-9]+(?:\.[0-9]+)*-p[1-9][0-9]*"
if re.fullmatch(tag_pattern, tag) is None:
    raise SystemExit(f"ERROR: Unexpected release tag returned by GitHub: {tag}")
if requested_tag != "latest" and tag != requested_tag:
    raise SystemExit(f"ERROR: GitHub returned {tag}, expected {requested_tag}")

assets = release.get("assets", [])
if not 8 <= len(assets) <= 20:
    raise SystemExit(f"ERROR: Unexpected asset count: {len(assets)}")
names = [asset.get("name", "") for asset in assets]
if len(names) != len(set(names)):
    raise SystemExit("ERROR: Duplicate release asset names.")
safe_name = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+\-]*")
for name in names:
    if safe_name.fullmatch(name) is None:
        raise SystemExit(f"ERROR: Unsafe release asset name: {name!r}")

required_names = {
    "SHA256SUMS",
    "PACKAGE-MANIFEST.tsv",
    "BUILD-METADATA.txt",
    "ZFS-BUILD-METADATA.txt",
    "bbrv3.sysctl.conf",
    "enable-bbrv3.sh",
    "install-bbrv3.sh",
    "download-and-install.sh",
}
missing = sorted(required_names.difference(names))
if missing:
    raise SystemExit("ERROR: Missing release assets: " + ", ".join(missing))
required_deb_prefixes = (
    "linux-image-unsigned-",
    "linux-modules-",
    "linux-main-modules-zfs-",
    "linux-headers-",
    "linux-buildinfo-",
)
for prefix in required_deb_prefixes:
    if not any(name.startswith(prefix) and name.endswith(".deb") for name in names):
        raise SystemExit(f"ERROR: Missing required Debian package type: {prefix}*.deb")

total_size = sum(int(asset.get("size", -1)) for asset in assets)
if total_size < 1 or total_size > 2_000_000_000:
    raise SystemExit(f"ERROR: Unexpected total release size: {total_size}")

output = pathlib.Path(output_path)
expected_prefix = f"/{repository}/releases/download/{urllib.parse.quote(tag, safe='')}/"
for asset in assets:
    name = asset["name"]
    size = int(asset.get("size", -1))
    url = asset.get("browser_download_url", "")
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https" or parsed.netloc != "github.com" or not parsed.path.startswith(expected_prefix):
        raise SystemExit(f"ERROR: Unexpected download URL for {name}")
    request = urllib.request.Request(url, headers={"User-Agent": "ubuntu-bbrv3-installer/1"})
    temporary = output / f".{name}.part"
    with urllib.request.urlopen(request, timeout=120) as response, open(temporary, "wb") as target:
        while True:
            block = response.read(1024 * 1024)
            if not block:
                break
            target.write(block)
    if temporary.stat().st_size != size:
        raise SystemExit(f"ERROR: Size mismatch for {name}")
    os.replace(temporary, output / name)

print(f"Downloaded stable release {tag} ({total_size} bytes).")
PY

rm -f -- "$download_dir/release.json"
(
  cd "$download_dir"
  sha256sum --check --strict SHA256SUMS
  # Keep the release files unchanged so their complete SHA256SUMS remains valid.
  # The executable installer comes from this single versioned file, not mutable main.
  mkdir .installer-runtime
  cat > .installer-runtime/install-bbrv3.sh <<'BBRV3_INSTALLER_V1'
#!/usr/bin/env bash
# Run from an extracted, reviewed release directory. Never selects latest prerelease.
set -euo pipefail
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $EUID == 0 ]] || die 'Run with sudo.'
mode="${1:-install}"
state=/var/lib/bbrv3-installer
if [[ "$mode" == test ]]; then
  expected="$(cat "$state/expected-release")"
  [[ "$(uname -r)" == "$expected" ]] || die "Booted $(uname -r), expected $expected. Select the target kernel in GRUB."
  "$state/enable-bbrv3.sh" "$expected"
  zfs_package="linux-main-modules-zfs-$expected"
  [[ "$(dpkg-query -W -f='${db:Status-Abbrev}' "$zfs_package" 2>/dev/null || true)" == ii* ]] ||
    die "$zfs_package is not fully installed."
  modprobe zfs
  zfs_path="$(readlink -f "$(modinfo -n zfs)")"
  zfs_vermagic="$(modinfo -F vermagic zfs || true)"
  [[ -r "$zfs_path" ]] || die 'The installed OpenZFS module file is not readable.'
  [[ "$zfs_path" == "/usr/lib/modules/$expected/ubuntu/dkms/zfs/zfs.ko.zst" ]] ||
    die "OpenZFS resolved to an unexpected module path: $zfs_path"
  zfs_owner="$(dpkg-query -S "$zfs_path" 2>/dev/null || true)"
  zfs_owner="${zfs_owner%%: *}"
  zfs_owner="${zfs_owner%%:*}"
  [[ "$zfs_owner" == "$zfs_package" ]] ||
    die "The loaded OpenZFS module is not owned by $zfs_package."
  [[ "${zfs_vermagic%% *}" == "$expected" ]] ||
    die "OpenZFS vermagic does not match $expected: ${zfs_vermagic:-missing}"
  [[ -n "$(cat /sys/module/zfs/version 2>/dev/null || true)" ]] ||
    die 'The matching OpenZFS module did not load.'
  # Exercise a real TCP connection with BBR, without sending external traffic.
  python3 - <<'PY'
import socket
with socket.socket() as listener, socket.socket() as client:
    listener.bind(('127.0.0.1', 0))
    listener.listen(1)
    client.settimeout(5)
    client.setsockopt(socket.IPPROTO_TCP, socket.TCP_CONGESTION, b'bbr')
    client.connect(listener.getsockname())
    with listener.accept()[0] as peer:
        peer.settimeout(5)
        client.sendall(b'bbrv3-smoke-test')
        data = b''
        while len(data) < 16:
            chunk = peer.recv(16 - len(data))
            if not chunk:
                raise RuntimeError('Unexpected TCP EOF')
            data += chunk
        assert data == b'bbrv3-smoke-test'
        assert client.getsockopt(socket.IPPROTO_TCP, socket.TCP_CONGESTION, 16).rstrip(b'\0') == b'bbr'
print('PASS: local TCP transfer using bbr (not a throughput or WAN test).')
PY
  printf 'PASS: booted %s and loaded BBRv3 plus matching OpenZFS modules; review journalctl -k -b for kernel warnings.\n' "$expected"
  exit 0
fi
[[ "$mode" == install ]] || die 'Usage: install-bbrv3.sh install [--reboot] | test'
allow_no_fallback=false
reboot_requested=false
shift
while (( $# > 0 )); do
  case "$1" in
    --allow-no-fallback) allow_no_fallback=true ;;
    --reboot) reboot_requested=true ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done
# shellcheck source=/dev/null
source /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_ID" == 26.04 ]] || die 'Requires Ubuntu 26.04.'
[[ "$(dpkg --print-architecture)" == amd64 ]] || die 'Requires amd64.'
for tool in systemctl systemd-detect-virt python3 apt-get dpkg dpkg-deb dpkg-query findmnt modinfo modprobe readlink update-grub sha256sum; do
  command -v "$tool" >/dev/null || die "Missing prerequisite: $tool"
done
if systemd-detect-virt --container --quiet; then die 'Containers cannot replace the host kernel.'; fi
[[ -d /run/systemd/system && -f /boot/grub/grub.cfg ]] || die 'Requires systemd and GRUB.'
dpkg_audit="$(dpkg --audit 2>&1 || true)"
[[ -z "$dpkg_audit" ]] || {
  printf '%s\n' "$dpkg_audit" >&2
  die 'Repair the existing dpkg state before installing another kernel.'
}
apt-get check
if [[ -d /sys/firmware/efi ]]; then
  command -v mokutil >/dev/null || die 'Missing prerequisite for the EFI Secure Boot check: mokutil'
  sb="$(mokutil --sb-state)" || die 'Cannot determine Secure Boot state.'
  grep -qi 'SecureBoot disabled' <<<"$sb" || die 'Unsigned release requires Secure Boot disabled; signed installations need a separate procedure.'
fi
for file in SHA256SUMS enable-bbrv3.sh bbrv3.sysctl.conf; do
  [[ -f "$file" ]] || die "Run in the release directory; missing $file"
done
sha256sum --check --strict SHA256SUMS
shopt -s nullglob
packages=(./*.deb)
(( ${#packages[@]} > 0 )) || die 'No packages.'
expected=''
version=''
declare -A package_files=()
for package in "${packages[@]}"; do
  name="$(dpkg-deb -f "$package" Package)"
  current_version="$(dpkg-deb -f "$package" Version)"
  [[ "$current_version" == *+bbrv3.* ]] || die "Not a BBRv3 package: $package"
  [[ -z "$version" || "$version" == "$current_version" ]] || die 'Mixed package versions.'
  version="$current_version"
  [[ -z "${package_files[$name]:-}" ]] || die "Duplicate package: $name"
  package_files["$name"]="$package"
  # Verify every selected deb, including any extra file not in SHA256SUMS.
  digest="$(sha256sum "$package")"
  digest="${digest%% *}"
  grep -Fx -- "$digest  ${package#./}" SHA256SUMS >/dev/null || die "Unlisted package: $package"
  if [[ "$name" == linux-image-unsigned-* ]]; then
    [[ -z "$expected" ]] || die 'Multiple kernel images.'
    expected="${name#linux-image-unsigned-}"
  fi
done
[[ "$expected" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]{5,}-generic$ ]] || die 'Missing or unexpected custom kernel image.'
[[ "$(uname -r)" != "$expected" ]] || die 'Target release is already running; use test, or upgrade from a different kernel to avoid replacing loaded modules.'

abi_release="${expected%-generic}"
required_packages=(
  "linux-image-unsigned-$expected"
  "linux-modules-$expected"
  "linux-main-modules-zfs-$expected"
  "linux-headers-$expected"
  "linux-headers-$abi_release"
  "linux-buildinfo-$expected"
)
for required_package in "${required_packages[@]}"; do
  [[ -n "${package_files[$required_package]:-}" ]] || die "Release is missing $required_package"
done
for package_name in "${!package_files[@]}"; do
  case "$package_name" in
    "linux-image-unsigned-$expected"|"linux-modules-$expected"|"linux-main-modules-zfs-$expected"|\
    "linux-headers-$expected"|"linux-headers-$abi_release"|"linux-buildinfo-$expected"|\
    "linux-lib-rust-$expected") ;;
    *) die "Unexpected package in release directory: $package_name" ;;
  esac
done

modules_depends="$(dpkg-deb -f "${package_files[linux-modules-$expected]}" Depends)"
grep -Fq "linux-main-modules-zfs-$expected" <<<"$modules_depends" ||
  die "linux-modules-$expected does not require its matching OpenZFS package."
zfs_depends="$(dpkg-deb -f "${package_files[linux-main-modules-zfs-$expected]}" Depends)"
grep -Fq "linux-image-$expected | linux-image-unsigned-$expected" <<<"$zfs_depends" ||
  die 'The OpenZFS package does not require the matching kernel image.'

fallback_release=''
mapfile -t installed_images < <(
  dpkg-query -W \
    -f='${db:Status-Abbrev}\t${binary:Package}\t${Version}\t${source:Package}\n' \
    'linux-image-[0-9]*-generic' 'linux-image-unsigned-[0-9]*-generic' 2>/dev/null || true
)
for image_record in "${installed_images[@]}"; do
  IFS=$'\t' read -r image_status image_package image_version image_source <<<"$image_record"
  [[ "$image_status" == ii* ]] || continue
  image_package="${image_package%%:*}"
  [[ "$image_version" != *+bbrv3.* ]] || continue
  [[ "$image_source" == linux || "$image_source" == linux-signed ]] || continue
  case "$image_package" in
    linux-image-unsigned-*) candidate_release="${image_package#linux-image-unsigned-}" ;;
    linux-image-*) candidate_release="${image_package#linux-image-}" ;;
    *) continue ;;
  esac
  [[ "$candidate_release" != "$expected" && -s "/boot/vmlinuz-$candidate_release" ]] || continue
  fallback_release="$candidate_release"
  break
done
if [[ -z "$fallback_release" ]]; then
  [[ "$allow_no_fallback" == true ]] ||
    die 'No fully installed Canonical fallback kernel was found. First run: apt-get update && apt-get install linux-image-generic'
  printf '%s\n' 'WARNING: No verified Canonical fallback kernel. Boot failure may require the provider rescue console.' >&2
else
  printf 'Canonical fallback kernel: %s\n' "$fallback_release"
fi

mounted_zfs="$(findmnt --raw --noheadings --types zfs --output TARGET 2>/dev/null || true)"
imported_zpools=''
if command -v zpool >/dev/null; then
  imported_zpools="$(zpool list -H -o name 2>/dev/null || true)"
fi
if [[ -n "$mounted_zfs" || -n "$imported_zpools" ]]; then
  printf '%s\n' 'ZFS usage detected; the matching real OpenZFS kernel package is present and will be installed.'
fi
# Dependency failures must stop before package installation or reboot.
apt-get --simulate --no-remove install "${packages[@]}"
apt-get --yes --no-remove install "${packages[@]}"
apt-get check
post_install_audit="$(dpkg --audit 2>&1 || true)"
[[ -z "$post_install_audit" ]] || {
  printf '%s\n' "$post_install_audit" >&2
  die 'dpkg reported an incomplete kernel installation.'
}
for required_package in "${required_packages[@]}"; do
  [[ "$(dpkg-query -W -f='${db:Status-Abbrev}' "$required_package" 2>/dev/null || true)" == ii* ]] ||
    die "$required_package was not fully configured."
done
[[ -s "/boot/vmlinuz-$expected" && -s "/boot/initrd.img-$expected" ]] || die 'Missing kernel or initramfs.'
installed_zfs_path="$(modinfo -k "$expected" -n zfs 2>/dev/null || true)"
if [[ -n "$installed_zfs_path" ]]; then
  installed_zfs_path="$(readlink -f "$installed_zfs_path")"
fi
[[ "$installed_zfs_path" == "/usr/lib/modules/$expected/ubuntu/dkms/zfs/zfs.ko.zst" ]] ||
  die "The target kernel would resolve OpenZFS from an unexpected path: ${installed_zfs_path:-missing}"
installed_zfs_owner="$(dpkg-query -S "$installed_zfs_path" 2>/dev/null || true)"
installed_zfs_owner="${installed_zfs_owner%%: *}"
installed_zfs_owner="${installed_zfs_owner%%:*}"
[[ "$installed_zfs_owner" == "linux-main-modules-zfs-$expected" ]] ||
  die 'The target OpenZFS module is not owned by the matching release package.'
update-grub
install -d -m 0700 "$state"
install -m 0755 "${BASH_SOURCE[0]}" "$state/install-bbrv3.sh"
install -m 0755 enable-bbrv3.sh "$state/enable-bbrv3.sh"
install -m 0644 bbrv3.sysctl.conf "$state/bbrv3.sysctl.conf"
printf '%s\n' "$expected" > "$state/expected-release"
cat > /etc/systemd/system/bbrv3-verify.service <<'UNIT'
[Unit]
Description=Enable and smoke-test the installed BBRv3 kernel
After=network.target
ConditionPathExists=/var/lib/bbrv3-installer/expected-release
[Service]
Type=oneshot
ExecStart=/var/lib/bbrv3-installer/install-bbrv3.sh test
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable bbrv3-verify.service
printf 'Installed %s. Select this kernel in GRUB. After boot: journalctl -u bbrv3-verify -b --no-pager\n' "$expected"
printf 'Original kernels are retained. This script does not change your GRUB default.\n'
if [[ "$reboot_requested" == true ]]; then systemctl reboot; fi
BBRV3_INSTALLER_V1
  bash .installer-runtime/install-bbrv3.sh install "${install_options[@]}"
)
