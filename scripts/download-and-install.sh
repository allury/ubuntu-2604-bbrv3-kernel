#!/usr/bin/env bash
# Download one immutable stable GitHub Release, verify it, install it, and
# optionally reboot. The post-boot systemd service performs the runtime test.
set -euo pipefail

readonly repository='allury/ubuntu-2604-bbrv3-kernel'

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ $EUID == 0 ]] || die 'Run with sudo.'
requested_tag='latest'
reboot_option=''
fallback_option=''
while (( $# > 0 )); do
  case "$1" in
    --tag)
      (( $# >= 2 )) || die '--tag requires a release tag.'
      requested_tag="$2"
      shift 2
      ;;
    --reboot)
      reboot_option='--reboot'
      shift
      ;;
    --allow-no-fallback)
      fallback_option='--allow-no-fallback'
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
  chmod 0755 download-and-install.sh enable-bbrv3.sh install-bbrv3.sh
  installer_args=(install)
  if [[ -n "$reboot_option" ]]; then installer_args+=("$reboot_option"); fi
  if [[ -n "$fallback_option" ]]; then installer_args+=("$fallback_option"); fi
  bash ./install-bbrv3.sh "${installer_args[@]}"
)
