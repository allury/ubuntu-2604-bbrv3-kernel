#!/usr/bin/env bash
# Independently versioned installer v1.2.0, derived from stable p2.
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
    --no-boot-once)
      install_options+=(--no-boot-once)
      shift
      ;;
    -h|--help)
      printf 'Usage: %s [--tag ubuntu-26.04-bbrv3-VERSION-pN] [--reboot] [--allow-no-fallback] [--no-boot-once]\n' "$0"
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

curl --fail --location --silent --show-error --retry 3 --connect-timeout 20 --max-time 120 \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  "$api_url" > "$download_dir/release.json"

python3 - "$download_dir/release.json" "$download_dir" "$repository" "$requested_tag" <<'PY'
import json
import os
import pathlib
import re
import shutil
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
if shutil.disk_usage(output_path).free < total_size + 256 * 1024 * 1024:
    raise SystemExit("ERROR: Insufficient download space (assets plus 256 MiB reserve required).")

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
  cat > .installer-runtime/enable-bbrv3.sh <<'BBRV3_ENABLE_V1_1'
#!/usr/bin/env bash
set -euo pipefail
[[ $EUID == 0 && "$(uname -r)" == "${1:?Expected kernel required}" ]] || exit 1
modprobe tcp_bbr
[[ "$(cat /sys/module/tcp_bbr/version)" == 3 ]] || exit 1
[[ "$(modinfo -F version tcp_bbr)" == 3 ]] || exit 1
vermagic="$(modinfo -F vermagic tcp_bbr)"
[[ "${vermagic%% *}" == "$(uname -r)" ]] || exit 1
install -D -m 0644 /var/lib/bbrv3-installer/bbrv3.sysctl.conf /etc/sysctl.d/99-bbrv3.conf
# Apply only this installer's configuration, not unrelated system settings.
sysctl -p /etc/sysctl.d/99-bbrv3.conf
[[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == bbr ]] || exit 1
[[ "$(sysctl -n net.core.default_qdisc)" == fq ]] || exit 1
printf '%s\n' 'PASS: BBRv3 enabled; default qdisc=fq (existing interface qdiscs are unchanged).'
BBRV3_ENABLE_V1_1
  cat > .installer-runtime/bbrv3.sysctl.conf <<'BBRV3_CONFIG_V1_1'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
BBRV3_CONFIG_V1_1
  cat > .installer-runtime/install-bbrv3.sh <<'BBRV3_INSTALLER_V1'
#!/usr/bin/env bash
# Run from an extracted, reviewed release directory. Never selects latest prerelease.
set -euo pipefail
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $EUID == 0 ]] || die 'Run with sudo.'
mode="${1:-install}"
state=/var/lib/bbrv3-installer
# Trial boot: GRUB keeps the running kernel as its saved default and boots
# the new kernel once, through a temporary entry with panic=10, so a kernel
# that panics or cannot mount its root returns to the saved default by
# itself. bbrv3-verify makes the new kernel the default only after it passes.
grub_default_config=/etc/default/grub.d/99-bbrv3-installer.cfg
trial_config=/boot/grub/custom.cfg
trial_marker='# Temporary BBRv3 trial boot entry; bbrv3-verify removes it.'
boot_once_state="$state/boot-once"

# Print the GRUB menu path of a kernel's normal entry, for example
# gnulinux-advanced-UUID>gnulinux-7.0.0-13402-generic-advanced-UUID.
grub_entry_path() {
  awk -v release="$1" -v q="'" '
    function entry_id(line) {
      if (!match(line, "[$]menuentry_id_option " q "[^" q "]+" q)) return ""
      return substr(line, RSTART + 22, RLENGTH - 23)
    }
    BEGIN { gsub(/[.]/, "[.]", release) }
    /^submenu / { submenu = entry_id($0) }
    /^}/ { submenu = "" }
    /^[[:space:]]*menuentry / {
      id = entry_id($0)
      if (id ~ ("^gnulinux-" release "-advanced-")) {
        print (submenu == "" ? id : submenu ">" id)
        exit
      }
    }
  ' /boot/grub/grub.cfg
}

# Print a copy of the normal entry with the given id as the trial entry. It
# drops recordfail, which would stop the next boot at the GRUB menu after a
# failed trial instead of returning to the saved default unattended.
trial_entry_block() {
  awk -v id="$1" -v q="'" -v title="BBRv3 trial boot of $2" '
    !copying && index($0, "$menuentry_id_option " q id q) {
      copying = 1
      indent = $0
      sub(/[^[:space:]].*$/, "", indent)
      print "menuentry " q title q " --id bbrv3-trial {"
      next
    }
    copying && $0 == indent "}" { print "}"; found = 1; exit }
    copying && /^[[:space:]]*recordfail[[:space:]]*$/ { next }
    copying {
      if ($0 ~ /^[[:space:]]*linux[[:space:]]/) $0 = $0 " panic=10"
      print
    }
    END { if (!found) exit 1 }
  ' /boot/grub/grub.cfg
}

remove_trial_entry() {
  if [[ -f "$trial_config" ]] && grep -Fxq "$trial_marker" "$trial_config"; then
    rm -f -- "$trial_config"
  fi
}

if [[ "$mode" == test ]]; then
  expected="$(cat "$state/expected-release")"
  if [[ "$(uname -r)" != "$expected" && -f "$boot_once_state" ]]; then
    remove_trial_entry
    rm -f -- "$boot_once_state"
    die "The trial boot of $expected did not pass, so the system runs $(uname -r) and the default boot entry is unchanged. Check the provider console output of that boot before retrying."
  fi
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
  if [[ -f "$boot_once_state" ]]; then
    # A kernel that boots but loses the network must not become the default.
    [[ -n "$(ip route show default 2>/dev/null)" ]] ||
      die "No default route after booting $expected; the previous kernel stays the default boot entry."
    grub-set-default "$(cat "$boot_once_state")"
    remove_trial_entry
    rm -f -- "$boot_once_state"
    printf 'PASS: %s passed its trial boot and is now the default boot entry.\n' "$expected"
  fi
  exit 0
fi
[[ "$mode" == install ]] || die 'Usage: install-bbrv3.sh install [--reboot] [--allow-no-fallback] [--no-boot-once] | test'
allow_no_fallback=false
reboot_requested=false
boot_once_requested=true
shift
while (( $# > 0 )); do
  case "$1" in
    --allow-no-fallback) allow_no_fallback=true ;;
    --reboot) reboot_requested=true ;;
    --no-boot-once) boot_once_requested=false ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done
# shellcheck source=/dev/null
source /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_ID" == 26.04 ]] || die 'Requires Ubuntu 26.04.'
[[ "$(dpkg --print-architecture)" == amd64 ]] || die 'Requires amd64.'
for tool in systemctl systemd-detect-virt python3 apt-get dpkg dpkg-deb dpkg-query findmnt modinfo modprobe readlink update-grub sha256sum flock; do
  command -v "$tool" >/dev/null || die "Missing prerequisite: $tool"
done
if systemd-detect-virt --container --quiet; then die 'Containers cannot replace the host kernel.'; fi
[[ -d /run/systemd/system && -f /boot/grub/grub.cfg ]] || die 'Requires systemd and GRUB.'
exec 9>/run/lock/bbrv3-installer.lock
flock --nonblock 9 || die 'Another BBRv3 installation is in progress.'
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

boot_files_ready() {
  local release="$1"
  [[ -s "/boot/vmlinuz-$release" && -s "/boot/initrd.img-$release" ]] &&
    grep -Fq -- "vmlinuz-$release" /boot/grub/grub.cfg &&
    grep -Fq -- "initrd.img-$release" /boot/grub/grub.cfg
}
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
  [[ "$candidate_release" != "$expected" ]] || continue
  boot_files_ready "$candidate_release" || continue
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

# Decide before changing anything whether GRUB can take a single trial boot.
# GRUB must clear the one-time entry itself while booting; where it cannot
# write its environment, a failing kernel would be retried on every boot.
# The file system and storage checks follow Ubuntu's own recordfail logic.
boot_once_blocker=''
if [[ "$boot_once_requested" != true ]]; then
  boot_once_blocker='disabled with --no-boot-once'
else
  for tool in grub-editenv grub-probe grub-reboot grub-set-default ip; do
    command -v "$tool" >/dev/null || { boot_once_blocker="$tool is not installed"; break; }
  done
fi
if [[ -z "$boot_once_blocker" ]]; then
  grub_fs="$(grub-probe --target=fs /boot/grub 2>/dev/null || true)"
  grub_abstraction="$(grub-probe --target=abstraction /boot/grub 2>/dev/null || true)"
  configured_default="$(
    set +eu
    GRUB_DEFAULT=0
    for config in /etc/default/grub /etc/default/grub.d/*.cfg; do
      [[ -f "$config" && "$config" != "$grub_default_config" ]] || continue
      # shellcheck source=/dev/null
      . "$config"
    done
    printf '%s' "${GRUB_DEFAULT:-0}"
  )"
  case "$grub_fs" in
    ''|btrfs|cifs|cpiofs|newc|odc|romfs|squash4|tarfs|zfs)
      boot_once_blocker="GRUB cannot write its environment on the ${grub_fs:-unknown} file system of /boot/grub"
      ;;
    *)
      if [[ -n "$grub_abstraction" ]]; then
        boot_once_blocker="GRUB cannot write its environment through ${grub_abstraction//$'\n'/ }"
      elif [[ "$configured_default" != 0 ]]; then
        boot_once_blocker="GRUB_DEFAULT is already set to $configured_default"
      fi
      ;;
  esac
fi
if [[ -z "$boot_once_blocker" ]]; then
  printf 'The new kernel will get a single trial boot; %s stays the default until it passes.\n' "$(uname -r)"
else
  printf 'No trial boot: %s.\n' "$boot_once_blocker"
fi

# Dependency failures must stop before package installation or reboot.
python3 - "${packages[@]}" <<'SPACE_CHECK'
import os
import shutil
import subprocess
import sys

# Conservatively budget all unpacked package data on every destination device.
# Same-device requirements are summed, not checked independently.
unpacked = sum(int(subprocess.check_output(
    ['dpkg-deb', '-f', p, 'Installed-Size'], text=True).strip()) * 1024
    for p in sys.argv[1:])
requirements = {}
for path, amount in [('/usr', unpacked + 512 * 1024**2),
                     ('/boot', 512 * 1024**2), ('/var', 256 * 1024**2)]:
    device = os.stat(path).st_dev
    previous = requirements.get(device, (path, 0))
    requirements[device] = (previous[0], previous[1] + amount)
for path, required in requirements.values():
    if shutil.disk_usage(path).free < required:
        raise SystemExit(f'ERROR: Insufficient space on {path}: require {required} bytes free.')
print('PASS: conservative installation disk-space preflight')
SPACE_CHECK
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
if [[ -z "$boot_once_blocker" ]]; then
  install -d /etc/default/grub.d
  printf '%s\n' \
    '# Written by the BBRv3 installer. GRUB boots the saved entry, which' \
    '# bbrv3-verify moves to a new kernel only after its trial boot passed.' \
    '# Delete this file and run update-grub to boot the first entry again.' \
    'GRUB_DEFAULT=saved' > "$grub_default_config"
elif [[ -f "$grub_default_config" ]]; then
  # A saved default from an earlier install would keep booting that kernel.
  rm -f -- "$grub_default_config"
fi
update-grub
boot_files_ready "$expected" || die 'Target image/initramfs or GRUB references missing; refusing reboot.'
if [[ -n "$fallback_release" ]]; then
  boot_files_ready "$fallback_release" || die 'Fallback boot files disappeared; refusing reboot.'
fi
install -d -m 0700 "$state"
install -m 0755 "${BASH_SOURCE[0]}" "$state/install-bbrv3.sh"
runtime_dir="$(dirname -- "${BASH_SOURCE[0]}")"
install -m 0755 "$runtime_dir/enable-bbrv3.sh" "$state/enable-bbrv3.sh"
install -m 0644 "$runtime_dir/bbrv3.sysctl.conf" "$state/bbrv3.sysctl.conf"
printf '%s\n' "$expected" > "$state/expected-release"
cat > /etc/systemd/system/bbrv3-verify.service <<'UNIT'
[Unit]
Description=Enable and smoke-test the installed BBRv3 kernel
Wants=network-online.target
After=network-online.target
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

# Arrange the trial boot last, once everything else is in place.
revert_boot_once() {
  remove_trial_entry
  rm -f -- "$grub_default_config" "$boot_once_state"
  grub-editenv - unset next_entry saved_entry || true
  update-grub
}
if [[ -z "$boot_once_blocker" ]]; then
  target_entry="$(grub_entry_path "$expected")"
  fallback_entry="$(grub_entry_path "$(uname -r)")"
  if [[ -z "$target_entry" || -z "$fallback_entry" ]]; then
    boot_once_blocker='GRUB has no menu entry for the new or the running kernel'
    revert_boot_once
  fi
fi
if [[ -z "$boot_once_blocker" ]]; then
  trial_target="$target_entry"
  trial_block=''
  if grep -q 'custom\.cfg' /boot/grub/grub.cfg &&
    { [[ ! -e "$trial_config" ]] || grep -Fxq "$trial_marker" "$trial_config"; }; then
    trial_block="$(trial_entry_block "${target_entry##*>}" "$expected" || true)"
  fi
  if [[ "$trial_block" == *' --id bbrv3-trial {'* && "$trial_block" == *' panic=10'* ]]; then
    printf '%s\n%s\n' "$trial_marker" "$trial_block" > "$trial_config"
    trial_target=bbrv3-trial
  else
    printf '%s\n' 'NOTE: No temporary trial entry was written; the trial uses the normal entry without panic=10, so a kernel that hangs or panics needs a reset before GRUB falls back.'
  fi
  grub-set-default "$fallback_entry"
  grub-reboot "$trial_target"
  grub_env="$(grub-editenv list)"
  if ! grep -Fxq "saved_entry=$fallback_entry" <<<"$grub_env" ||
    ! grep -Fxq "next_entry=$trial_target" <<<"$grub_env"; then
    revert_boot_once
    die 'GRUB did not record the trial boot; restored booting the first menu entry.'
  fi
  printf '%s\n' "$target_entry" > "$boot_once_state"
  printf 'Installed %s. The next boot tries it once; if it does not come up and pass bbrv3-verify, the following boot returns to %s.\n' "$expected" "$(uname -r)"
  printf 'bbrv3-verify makes %s the default boot entry after it passes. After boot: journalctl -u bbrv3-verify -b --no-pager\n' "$expected"
else
  printf 'Installed %s without a trial boot (%s); GRUB boots it by default because it is listed first.\n' "$expected" "$boot_once_blocker"
  printf 'After boot: journalctl -u bbrv3-verify -b --no-pager\n'
fi
printf 'Original kernels are retained.\n'
if [[ "$reboot_requested" == true ]]; then systemctl reboot; fi
BBRV3_INSTALLER_V1
  bash .installer-runtime/install-bbrv3.sh install "${install_options[@]}"
)
