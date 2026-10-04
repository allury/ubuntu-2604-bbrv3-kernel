#!/usr/bin/env bash
# Independently versioned installer v1.3.0, derived from stable p2.
# Without arguments in a terminal it shows a menu. With options, or without a
# terminal, it downloads one stable GitHub Release, verifies it, installs it
# and optionally reboots, as earlier versions did. The post-boot systemd
# service performs the runtime test.
set -euo pipefail

readonly repository='allury/ubuntu-2604-bbrv3-kernel'
readonly installer_version='1.3.0'

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

# Fetch a GitHub API URL. GITHUB_TOKEN, when set, lifts the low limit on
# anonymous requests that a shared address can run into. Only API requests
# carry it, never the asset downloads.
github_api() {
  local auth=()
  [[ -z "${GITHUB_TOKEN:-}" ]] || auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
  curl --fail --location --silent --show-error --retry 3 --connect-timeout 20 --max-time "${2:-120}" \
    -H 'Accept: application/vnd.github+json' \
    -H 'X-GitHub-Api-Version: 2022-11-28' \
    "${auth[@]}" "$1"
}

usage() {
  cat <<USAGE
用法：
  sudo bash $0
      在终端里运行时显示菜单。
  sudo bash $0 [install] [--reboot] [--tag 内核发布标签] [--allow-no-fallback] [--no-boot-once]
      直接安装或升级到最新正式内核，适合无人值守；不在终端里运行时也是这样。
  sudo bash $0 status
      检查 BBRv3。
  sudo bash $0 clean [--yes]
      清理旧的 BBRv3 内核。
  sudo bash $0 fallback [--yes]
      安装 Ubuntu 官方备用内核。
  sudo bash $0 restore [--yes] [--reboot]
      恢复官方内核并停用 BBRv3。
--yes 跳过确认，供脚本使用。
与他人共用出口 IP 时，GitHub 可能限制匿名查询；设置环境变量 GITHUB_TOKEN 即可，
例如 sudo GITHUB_TOKEN=... bash $0。
USAGE
}

for argument in "$@"; do
  case "$argument" in -h|--help) usage; exit 0 ;; esac
done
[[ $EUID == 0 ]] || die 'Run with sudo.'

# A terminal without arguments gets the menu. Anything else installs, as in
# earlier versions, unless the first argument names another action.
action=install
if (( $# == 0 )); then
  if [[ -t 0 && -t 1 ]]; then action=menu; fi
else
  case "$1" in
    install|status|clean|fallback|restore) action="$1"; shift ;;
  esac
fi
requested_tag='latest'
install_options=()
manage_options=()
while (( $# > 0 )); do
  case "$1" in
    --tag)
      [[ "$action" == install ]] || die '--tag only applies to installation.'
      (( $# >= 2 )) || die '--tag requires a release tag.'
      requested_tag="$2"
      shift 2
      ;;
    --reboot)
      case "$action" in
        install) install_options+=(--reboot) ;;
        restore) manage_options+=(--reboot) ;;
        *) die "--reboot does not apply to $action." ;;
      esac
      shift
      ;;
    --allow-no-fallback|--no-boot-once)
      [[ "$action" == install ]] || die "$1 only applies to installation."
      install_options+=("$1")
      shift
      ;;
    --yes)
      case "$action" in
        clean|fallback|restore) manage_options+=(--yes) ;;
        *) die "--yes does not apply to $action." ;;
      esac
      shift
      ;;
    *) die "Unknown option: $1" ;;
  esac
done

if [[ "$action" != install ]]; then
  for tool in bash curl mktemp python3 readlink sed systemctl; do
    command -v "$tool" >/dev/null || die "Missing prerequisite: $tool"
  done
  self="$(readlink -f -- "${BASH_SOURCE[0]}")"
  [[ -r "$self" ]] || die 'Run the installer from a downloaded file.'
  runtime_dir="$(mktemp -d /var/tmp/ubuntu-bbrv3-runtime.XXXXXX)"
  trap 'case "$runtime_dir" in /var/tmp/ubuntu-bbrv3-runtime.*) rm -rf -- "$runtime_dir" ;; esac' EXIT
  # The other actions run the same embedded logic as an installation, copied
  # out of this file; they download nothing.
  for part in BBRV3_ENABLE_V1_1:enable-bbrv3.sh BBRV3_CONFIG_V1_1:bbrv3.sysctl.conf \
    BBRV3_INSTALLER_V1:install-bbrv3.sh; do
    sed -n "/<<'${part%%:*}'\$/,/^${part%%:*}\$/p" "$self" | sed '1d;$d' > "$runtime_dir/${part#*:}"
    [[ -s "$runtime_dir/${part#*:}" ]] || die "Cannot read ${part#*:} from $self."
  done

  manage() {
    bash "$runtime_dir/install-bbrv3.sh" "$@"
  }

  # Ask a yes/no question; an empty answer takes the default, y or n.
  ask() {
    local reply
    read -r -p "$1" reply || return 1
    case "${reply:-$2}" in
      [Yy]|[Yy][Ee][Ss]) return 0 ;;
      *) return 1 ;;
    esac
  }

  pause() {
    local _
    read -r -p '按回车返回菜单。' _ || true
  }

  # Print the latest stable release as "tag kernel-release megabytes", or
  # nothing when GitHub cannot be reached.
  latest_release() {
    github_api "https://api.github.com/repos/$repository/releases/latest" 15 2>/dev/null |
      python3 -c '
import json, re, sys
release = json.load(sys.stdin)
tag = release.get("tag_name", "")
pattern = r"ubuntu-26\.04-bbrv3-[0-9]+\.[0-9]+\.[0-9]+-[0-9]+\.[0-9]+(?:\.[0-9]+)*-p[1-9][0-9]*"
if release.get("draft") or release.get("prerelease") or re.fullmatch(pattern, tag) is None:
    sys.exit(1)
assets = release.get("assets", [])
images = [a.get("name", "") for a in assets if a.get("name", "").startswith("linux-image-unsigned-")]
match = re.match(r"linux-image-unsigned-([^_]+)_", images[0]) if len(images) == 1 else None
if match is None:
    sys.exit(1)
print(tag, match.group(1), sum(int(a.get("size", 0)) for a in assets) // 1048576)
' 2>/dev/null || true
  }

  menu_install() {
    local latest="$1" tag='' release='' megabytes='' choice fallback status=0
    local options=(install)
    if [[ -n "$latest" ]]; then
      read -r tag release megabytes <<<"$latest"
      if [[ "$release" == "$(uname -r)" ]]; then
        printf '当前运行的已经是最新正式版 %s，不需要安装。\n' "$release"
        pause
        return
      fi
    fi
    if fallback="$(manage find-fallback)"; then
      printf '官方备用内核：%s\n' "$fallback"
    else
      printf '\n%s\n%s\n\n' '没有找到可用的官方备用内核。新内核试启动失败时会回到当前内核，' \
        '但如果当前内核以后也起不来，就只能用服务商的救援系统。'
      printf '%s\n' '  1) 先安装官方备用内核，再继续（推荐）' '  2) 不装备用内核，继续安装' '  0) 返回菜单'
      printf '\n'
      read -r -p '请选择 [0-2]：' choice || return
      case "$choice" in
        1)
          manage add-fallback --yes || {
            printf '%s\n' '官方备用内核没有装好，安装已取消。'
            pause
            return
          }
          ;;
        2) options+=(--allow-no-fallback) ;;
        *) return ;;
      esac
    fi
    ask "将下载并安装 ${tag:-最新正式版}${megabytes:+（约 $megabytes MB）}，新内核先试启动一次。继续吗？[Y/n] " y ||
      return
    bash "$self" "${options[@]}" || status=$?
    if (( status == 0 )); then
      if ask '安装完成，新内核会在下次开机时试启动一次。现在重启吗？[Y/n] ' y; then
        systemctl reboot
        exit 0
      fi
      printf '%s\n' '请稍后自行重启：sudo reboot'
    else
      printf '\n%s\n' '安装没有完成，系统没有重启，原因见上面的输出。'
    fi
    pause
  }

  menu_restore() {
    local status=0
    manage restore || status=$?
    if (( status == 0 )); then
      if ask '现在重启进入官方内核吗？[Y/n] ' y; then
        systemctl reboot
        exit 0
      fi
      printf '%s\n' '重启后生效：sudo reboot'
    fi
    pause
  }

  run_menu() {
    local latest choice
    printf '%s\n' '正在查询最新正式版。'
    latest="$(latest_release)"
    while :; do
      printf '\nUbuntu 26.04 BBRv3 内核管理 · 安装器 v%s\n\n' "$installer_version"
      manage status --summary || true
      if [[ -n "$latest" ]]; then
        printf '最新正式版：%s（%s）\n' "${latest%% *}" "$(cut -d' ' -f2 <<<"$latest")"
      else
        printf '%s\n' '最新正式版：查询失败，不影响其他功能'
      fi
      printf '\n'
      printf '%s\n' '  1) 安装或升级到最新正式版' '  2) 检查 BBRv3' '  3) 清理旧内核' \
        '  4) 安装官方备用内核' '  5) 恢复官方内核并停用 BBRv3' '  0) 退出'
      printf '\n'
      read -r -p '请选择 [0-5]：' choice || { printf '\n'; return 0; }
      case "$choice" in
        1) menu_install "$latest" ;;
        2) manage status || true; pause ;;
        3) manage clean || true; pause ;;
        4) manage add-fallback || true; pause ;;
        5) menu_restore ;;
        0|q|Q) return 0 ;;
        *) printf '%s\n' '请输入 0 到 5 之间的数字。' ;;
      esac
    done
  }

  case "$action" in
    status) manage status ;;
    clean) manage clean "${manage_options[@]}" ;;
    fallback) manage add-fallback "${manage_options[@]}" ;;
    restore) manage restore "${manage_options[@]}" ;;
    menu) run_menu ;;
  esac
  exit 0
fi

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

github_api "$api_url" > "$download_dir/release.json"

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
printf '%s\n' 'PASS: BBRv3 enabled; default qdisc=fq.'
# A link that came up before default_qdisc=fq applied, for example inside an
# initramfs that starts the network, keeps the kernel's built-in pfifo_fast.
# Move only those queues to fq; a queue anyone chose stays, and nothing here
# can fail the verification.
command -v tc >/dev/null || exit 0
while read -r device scope parent; do
  where=("$scope")
  [[ -z "$parent" ]] || where+=("$parent")
  if tc qdisc replace dev "$device" "${where[@]}" fq; then
    printf 'PASS: the %s queue of %s moved from pfifo_fast to fq.\n' "${where[*]}" "$device"
  else
    printf 'NOTE: the %s queue of %s stays pfifo_fast.\n' "${where[*]}" "$device"
  fi
done < <(tc qdisc show 2>/dev/null | awk '
  $1 == "qdisc" && $2 == "pfifo_fast" {
    device = ""
    where = ""
    for (i = 3; i <= NF; i++) {
      if ($i == "dev") device = $(i + 1)
      else if ($i == "root") where = "root"
      else if ($i == "parent") where = "parent " $(i + 1)
    }
    if (device != "" && where != "") print device, where
  }')
exit 0
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
# Ubuntu 26.04 builds its initramfs images with dracut. Where an initramfs
# starts the network, the links come up before default_qdisc=fq applies
# unless the image carries sch_fq and tcp_bbr.
dracut_config=/etc/dracut.conf.d/90-bbrv3.conf
dracut_line='force_drivers+=" sch_fq tcp_bbr "'

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

boot_files_ready() {
  local release="$1"
  [[ -s "/boot/vmlinuz-$release" && -s "/boot/initrd.img-$release" ]] &&
    grep -Fq -- "vmlinuz-$release" /boot/grub/grub.cfg &&
    grep -Fq -- "initrd.img-$release" /boot/grub/grub.cfg
}

# Print one line per installed kernel image: its release, its kind and
# whether its package is on hold. The kind is bbrv3 for this project's
# packages, official for Ubuntu's (source linux or linux-signed) and other for
# anything else. Held packages count as installed.
kernel_records() {
  { dpkg-query -W \
      -f='${db:Status-Abbrev}\t${binary:Package}\t${Version}\t${source:Package}\n' \
      'linux-image-[0-9]*-generic' 'linux-image-unsigned-[0-9]*-generic' 2>/dev/null || true; } |
    awk -F '\t' '
      $1 !~ /^[ih]i/ { next }
      {
        release = $2
        sub(/:.*$/, "", release)
        sub(/^linux-image-(unsigned-)?/, "", release)
        if (release in seen) next
        seen[release] = 1
        if ($3 ~ /[+]bbrv3[.]/) kind = "bbrv3"
        else if ($4 == "linux" || $4 == "linux-signed") kind = "official"
        else kind = "other"
        print release "\t" kind "\t" (substr($1, 1, 1) == "h" ? "held" : "-")
      }'
}

# Print the newest official kernel, other than the release given, whose
# image, initramfs and GRUB references are all in place.
find_fallback_release() {
  local release kind best=''
  while IFS=$'\t' read -r release kind _; do
    [[ "$kind" == official && "$release" != "${1:-}" ]] || continue
    boot_files_ready "$release" || continue
    best="$release"
  done < <(kernel_records | sort -t $'\t' -k1,1V)
  [[ -n "$best" ]] || return 1
  printf '%s\n' "$best"
}

# Print GRUB_DEFAULT as update-grub reads it, optionally without this
# installer's own setting.
grub_default_value() {
  local skip="${1:-}"
  (
    set +eu
    GRUB_DEFAULT=0
    for config in /etc/default/grub /etc/default/grub.d/*.cfg; do
      [[ -f "$config" && "$config" != "$skip" ]] || continue
      # shellcheck source=/dev/null
      . "$config"
    done
    printf '%s' "${GRUB_DEFAULT:-0}"
  )
}

# Print the kernel GRUB boots by default, or nothing if that cannot be told.
default_boot_release() {
  local default saved
  default="$(grub_default_value)"
  if [[ "$default" == saved ]]; then
    saved="$(grub-editenv list 2>/dev/null | sed -n 's/^saved_entry=//p' || true)"
    if [[ -n "$saved" ]]; then
      sed -n 's/^.*gnulinux-\([^>]*\)-advanced-[^>]*$/\1/p' <<<"$saved"
      return 0
    fi
  elif [[ "$default" != 0 ]]; then
    return 0
  fi
  # GRUB boots the first entry; print the kernel its linux line loads.
  awk '
    /^[[:space:]]*menuentry / { inside = 1 }
    inside && /^[[:space:]]*linux[[:space:]]/ {
      for (i = 2; i <= NF; i++)
        if ($i ~ /vmlinuz-/) { sub(/^.*vmlinuz-/, "", $i); print $i; exit }
    }' /boot/grub/grub.cfg
}

pending_trial() {
  local environment
  [[ ! -f "$boot_once_state" ]] || return 0
  environment="$(grub-editenv list 2>/dev/null || true)"
  grep -q '^next_entry=.' <<<"$environment"
}

megabytes() {
  local bytes
  bytes="$({ du -cbs "$@" 2>/dev/null || true; } | awk 'END { print $1 + 0 }')"
  printf '%d' $(( bytes / 1048576 ))
}

# Exercise a real TCP connection with BBR, without sending external traffic.
bbr_transfer_test() {
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
}

# Decide which old BBRv3 kernels can go. Input lines: release, kind and
# whether its boot files are ready. Output lines: "keep", the release and why,
# or "remove" and the release. The running and the default kernel stay, and
# so does a working fallback: an official kernel when there is one, else the
# newest other BBRv3 kernel.
clean_plan() {
  sort -t $'\t' -k1,1V | awk -F '\t' -v running="$1" -v boot_default="$2" '
    { release[NR] = $1; kind[NR] = $2; ready[NR] = $3 }
    END {
      for (i = 1; i <= NR; i++)
        if (release[i] != running && ready[i] == "yes" &&
            (kind[i] == "official" || release[i] == boot_default))
          fallback = 1
      for (i = NR; i >= 1; i--) {
        if (kind[i] != "bbrv3") continue
        if (release[i] == running) print "keep\t" release[i] "\trunning"
        else if (release[i] == boot_default) print "keep\t" release[i] "\tdefault"
        else if (!fallback && ready[i] == "yes") {
          fallback = 1
          print "keep\t" release[i] "\tfallback"
        } else print "remove\t" release[i]
      }
    }'
}

# Print the installed BBRv3 packages of one kernel release.
bbrv3_packages() {
  { dpkg-query -W -f='${db:Status-Abbrev}\t${binary:Package}\t${Version}\n' 'linux-*' 2>/dev/null || true; } |
    awk -F '\t' -v release="$1" -v headers="linux-headers-${1%-generic}" '
      $1 ~ /^.n/ || $3 !~ /[+]bbrv3[.]/ { next }
      {
        name = $2
        sub(/:.*$/, "", name)
        tail = "-" release
        if (name == headers ||
            (length(name) > length(tail) && substr(name, length(name) - length(tail) + 1) == tail))
          print name
      }'
}

# Ask before a change; --yes answers for scripts.
confirm() {
  local reply
  [[ "$assume_yes" != true ]] || return 0
  [[ -t 0 ]] || die '需要确认：非交互运行时请加 --yes。'
  read -r -p "$1 [y/N] " reply || reply=''
  case "$reply" in
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
  esac
  printf '%s\n' '已取消，没有做任何改动。'
  exit 10
}

take_lock() {
  exec 9>/run/lock/bbrv3-installer.lock
  flock --nonblock 9 || die '另一个 BBRv3 安装或管理操作正在进行。'
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
  bbr_transfer_test
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

# Management actions, run from the menu or as install-bbrv3.sh <action>.
assume_yes=false
reboot_after=false
summary_only=false
case "$mode" in
  status|find-fallback|add-fallback|clean|restore)
    shift
    while (( $# > 0 )); do
      case "$1:$mode" in
        --yes:add-fallback|--yes:clean|--yes:restore) assume_yes=true ;;
        --reboot:restore) reboot_after=true ;;
        --summary:status) summary_only=true ;;
        *) die "Unknown option for $mode: $1" ;;
      esac
      shift
    done
    ;;
esac

if [[ "$mode" == find-fallback ]]; then
  find_fallback_release
  exit 0
fi

if [[ "$mode" == status ]]; then
  running="$(uname -r)"
  running_kind="$(kernel_records | awk -F '\t' -v release="$running" '$1 == release { kind = $2 } END { print kind }')"
  case "$running_kind" in
    bbrv3) running_label='本项目的 BBRv3 内核' ;;
    official) running_label='Ubuntu 官方内核' ;;
    *) running_label='其他内核' ;;
  esac
  congestion="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 未知)"
  default_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo 未知)"
  bbr_version="$(cat /sys/module/tcp_bbr/version 2>/dev/null || true)"
  default_release="$(default_boot_release || true)"
  printf '当前内核：%s（%s）\n' "$running" "$running_label"
  printf '拥塞控制：%s%s，默认队列：%s\n' "$congestion" "${bbr_version:+（BBR 模块版本 $bbr_version）}" "$default_qdisc"
  printf '默认启动：%s\n' "${default_release:-无法确定}"
  [[ "$summary_only" != true ]] || exit 0

  if [[ -f /etc/systemd/system/bbrv3-verify.service ]]; then
    if systemctl is-active --quiet bbrv3-verify.service; then
      verify='本次开机已通过'
    elif systemctl is-failed --quiet bbrv3-verify.service; then
      verify='本次开机没有通过，原因见 journalctl -u bbrv3-verify -b --no-pager'
    else
      verify='本次开机还没有运行'
    fi
  else
    verify='没有安装'
  fi
  printf '开机验收：%s\n' "$verify"
  if pending_trial; then
    printf '试启动：%s 等待下次开机试启动\n' "$(cat "$state/expected-release" 2>/dev/null || echo 新内核)"
  else
    printf '%s\n' '试启动：没有待执行的试启动'
  fi
  if [[ -f "$dracut_config" ]]; then
    if [[ "$(cat "$dracut_config")" == "$dracut_line" ]]; then
      printf 'initramfs 模块：已配置 sch_fq 和 tcp_bbr（%s）\n' "$dracut_config"
    else
      printf 'initramfs 模块：%s 的内容与本安装器写入的不同\n' "$dracut_config"
    fi
  elif command -v dracut >/dev/null; then
    printf '%s\n' 'initramfs 模块：没有配置 sch_fq 和 tcp_bbr'
  fi
  printf '%s\n' '网卡队列：'
  queues="$(tc qdisc show 2>/dev/null | awk '
    $1 != "qdisc" { next }
    {
      device = ""
      root = 0
      for (i = 3; i <= NF; i++) {
        if ($i == "dev") device = $(i + 1)
        if ($i == "root") root = 1
      }
      if (device == "" || device == "lo") next
      if (root) {
        if (!(device in kind)) order[++count] = device
        kind[device] = $2
      } else if (index(" " children[device] " ", " " $2 " ") == 0) {
        children[device] = children[device] " " $2
      }
    }
    END {
      for (i = 1; i <= count; i++) {
        device = order[i]
        if (kind[device] == "noqueue") continue
        line = "  " device "：" kind[device]
        if (device in children) line = line "（子队列：" substr(children[device], 2) "）"
        print line
      }
    }' || true)"
  printf '%s\n' "${queues:-  没有读到网卡队列}"
  if [[ "$queues" == *pfifo_fast* && "$running_kind" == bbrv3 ]]; then
    printf '%s\n' '  pfifo_fast 是网卡比 fq 设置更早启用时留下的，开机验收服务每次开机会把它换成 fq。'
  fi
  printf '\n%s\n' '已安装的内核：'
  while IFS=$'\t' read -r release kind held; do
    case "$kind" in
      bbrv3) label='BBRv3' ;;
      official) label='官方' ;;
      *) label='其他' ;;
    esac
    marks=''
    [[ "$release" != "$running" ]] || marks+='，正在运行'
    [[ "$release" != "$default_release" ]] || marks+='，默认启动'
    [[ "$held" != held ]] || marks+='，已锁定（hold）'
    boot_files_ready "$release" || marks+='，启动文件不完整'
    printf '  %s  %s  /boot %s MB，模块 %s MB%s\n' "$release" "$label" \
      "$(megabytes /boot/{vmlinuz,initrd.img,System.map,config}-"$release")" \
      "$(megabytes "/usr/lib/modules/$release")" "$marks"
  done < <(kernel_records | sort -t $'\t' -k1,1Vr)
  printf '\n'
  if bbr_transfer_test >/dev/null 2>&1; then
    printf '%s\n' '自检：本机 TCP 传输使用 bbr 正常（不代表吞吐量或公网表现）'
  else
    printf '%s\n' '自检：本机 TCP 传输无法使用 bbr'
  fi
  exit 0
fi

if [[ "$mode" == add-fallback ]]; then
  if fallback="$(find_fallback_release)"; then
    printf '已有官方备用内核 %s，不需要再安装。\n' "$fallback"
    exit 0
  fi
  for tool in apt-get apt-cache flock systemd-detect-virt; do
    command -v "$tool" >/dev/null || die "Missing prerequisite: $tool"
  done
  confirm '将安装 Ubuntu 官方内核作为备用内核：虚拟机装 linux-image-virtual，物理机装 linux-image-generic。默认启动项不变。继续吗？'
  take_lock
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
  apt-get update
  meta=linux-image-generic
  # A virtual machine needs none of the firmware that linux-image-generic pulls in.
  if systemd-detect-virt --vm --quiet; then
    policy="$(apt-cache policy linux-image-virtual 2>/dev/null || true)"
    if grep -Eq '^[[:space:]]*Candidate: [0-9]' <<<"$policy"; then meta=linux-image-virtual; fi
  fi
  before="$(default_boot_release || true)"
  apt-get --simulate install "$meta" >/dev/null
  apt-get --yes install "$meta"
  fallback="$(find_fallback_release || true)"
  [[ -n "$fallback" ]] || die "$meta 已安装，但没有找到启动文件完整的官方内核，请检查 /boot 和 GRUB。"
  after="$(default_boot_release || true)"
  printf '已安装官方备用内核 %s（%s）。\n' "$fallback" "$meta"
  if [[ "$after" != "$before" ]]; then
    printf '注意：默认启动从 %s 变成了 %s。\n' "${before:-无法确定}" "${after:-无法确定}"
  fi
  exit 0
fi

if [[ "$mode" == clean ]]; then
  for tool in apt-get apt-mark flock grub-editenv update-grub; do
    command -v "$tool" >/dev/null || die "Missing prerequisite: $tool"
  done
  take_lock
  running="$(uname -r)"
  default_release="$(default_boot_release || true)"
  if pending_trial; then
    die '有一次试启动还没有完成，请先重启完成试启动，再清理旧内核。'
  fi
  [[ -n "$default_release" ]] || die '无法确定 GRUB 默认启动的内核，为安全起见不清理。'
  [[ "$default_release" == "$running" ]] ||
    die "当前运行的 $running 不是默认启动的 $default_release，请先重启进入默认内核，再清理旧内核。"
  if [[ "$(cat "$state/expected-release" 2>/dev/null || true)" == "$running" ]] &&
    systemctl is-failed --quiet bbrv3-verify.service; then
    die '本次开机验收没有通过，请先查看 journalctl -u bbrv3-verify -b --no-pager，再清理旧内核。'
  fi
  removable=()
  kept=''
  while IFS=$'\t' read -r verdict release reason; do
    if [[ "$verdict" == remove ]]; then
      removable+=("$release")
    elif [[ "$reason" == fallback ]]; then
      kept="$release"
    fi
  done < <(
    while IFS=$'\t' read -r release kind _; do
      ready=no
      if boot_files_ready "$release"; then ready=yes; fi
      printf '%s\t%s\t%s\n' "$release" "$kind" "$ready"
    done < <(kernel_records) | clean_plan "$running" "$default_release"
  )
  if (( ${#removable[@]} == 0 )); then
    if [[ -n "$kept" ]]; then
      printf '没有可以清理的旧内核：%s 是唯一的备用内核，需要保留。安装官方备用内核后就可以清理它。\n' "$kept"
    else
      printf '%s\n' '没有可以清理的旧内核。'
    fi
    exit 0
  fi
  packages=()
  for release in "${removable[@]}"; do
    while IFS= read -r package; do packages+=("$package"); done < <(bbrv3_packages "$release")
  done
  (( ${#packages[@]} > 0 )) || die '没有找到这些内核的软件包。'
  printf '%s\n' '将删除以下旧内核：'
  printf '  %s\n' "${removable[@]}"
  printf '%s\n' '涉及的软件包：'
  printf '  %s\n' "${packages[@]}"
  if [[ -n "$kept" ]]; then
    printf '保留 %s 作为备用内核。\n' "$kept"
  fi
  confirm '确认删除吗？'
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
  mapfile -t held < <(
    { dpkg-query -W -f='${db:Status-Abbrev}\t${binary:Package}\n' "${packages[@]}" 2>/dev/null || true; } |
      awk -F '\t' '$1 ~ /^h/ { name = $2; sub(/:.*$/, "", name); print name }'
  )
  rehold() {
    if (( ${#held[@]} > 0 )); then apt-mark hold "${held[@]}" >/dev/null || true; fi
  }
  if (( ${#held[@]} > 0 )); then
    apt-mark unhold "${held[@]}"
  fi
  # Remove exactly these packages and nothing that depends on them.
  simulation="$(apt-get --simulate --yes purge "${packages[@]}" 2>&1)" ||
    { rehold; printf '%s\n' "$simulation" >&2; die '删除前的模拟没有通过，没有删除任何软件包。'; }
  extra="$(awk '$1 == "Purg" || $1 == "Remv" { print $2 }' <<<"$simulation" |
    grep -Fvx -f <(printf '%s\n' "${packages[@]}") || true)"
  if [[ -n "$extra" ]]; then
    rehold
    die "删除这些内核会连带删除其他软件包，已停止：${extra//$'\n'/ }"
  fi
  apt-get --yes purge "${packages[@]}"
  update-grub
  boot_files_ready "$running" || die "删除后 $running 的启动文件不完整，请立即检查 /boot 和 GRUB。"
  printf '已删除：%s\n' "${removable[*]}"
  exit 0
fi

if [[ "$mode" == restore ]]; then
  for tool in flock grub-editenv grub-set-default update-grub; do
    command -v "$tool" >/dev/null || die "Missing prerequisite: $tool"
  done
  take_lock
  target="$(find_fallback_release || true)"
  [[ -n "$target" ]] || die '没有可以恢复到的官方内核，请先安装官方备用内核（菜单第 4 项，或运行 fallback）。'
  configured="$(grub_default_value "$grub_default_config")"
  if [[ "$configured" != 0 && "$configured" != saved ]]; then
    die "GRUB_DEFAULT 已被自定义为 $configured，请在 GRUB 配置里自行选择默认内核。"
  fi
  leftovers=()
  for path in /etc/systemd/system/bbrv3-verify.service /etc/sysctl.d/99-bbrv3.conf "$state"; do
    if [[ -e "$path" ]]; then leftovers+=("$path"); fi
  done
  dracut_ours=false
  if [[ -f "$dracut_config" && "$(cat "$dracut_config")" == "$dracut_line" ]]; then
    dracut_ours=true
    leftovers+=("$dracut_config")
  fi
  if (( ${#leftovers[@]} == 0 )) && [[ "$(default_boot_release || true)" == "$target" ]]; then
    printf '默认启动已经是官方内核 %s，也没有 BBRv3 的配置，不需要恢复。\n' "$target"
    exit 0
  fi
  printf '默认启动将改为官方内核 %s。\n' "$target"
  if (( ${#leftovers[@]} > 0 )); then
    printf '%s\n' '将删除以下 BBRv3 配置：'
    printf '  %s\n' "${leftovers[@]}"
  fi
  printf '%s\n' 'BBRv3 内核包保留，以后可以用"清理旧内核"删除。'
  confirm '确认恢复吗？'
  remove_trial_entry
  rm -f -- "$boot_once_state"
  if [[ "$configured" != saved ]]; then
    install -d /etc/default/grub.d
    printf '%s\n' \
      '# Written by the BBRv3 installer when it restored the official kernel.' \
      '# GRUB boots the saved entry. Delete this file and run update-grub to' \
      '# boot the first entry again.' \
      'GRUB_DEFAULT=saved' > "$grub_default_config"
  fi
  update-grub
  entry="$(grub_entry_path "$target")"
  [[ -n "$entry" ]] || die "GRUB 菜单里没有 $target 的启动项。"
  grub-editenv - unset next_entry || true
  grub-set-default "$entry"
  grub_environment="$(grub-editenv list)"
  grep -Fxq "saved_entry=$entry" <<<"$grub_environment" ||
    die 'GRUB 没有记录新的默认启动项，请检查 /boot/grub/grubenv。'
  if [[ -e /etc/systemd/system/bbrv3-verify.service ]]; then
    systemctl disable bbrv3-verify.service || true
    rm -f -- /etc/systemd/system/bbrv3-verify.service
    systemctl daemon-reload
  fi
  rm -f -- /etc/sysctl.d/99-bbrv3.conf
  if [[ "$dracut_ours" == true ]]; then rm -f -- "$dracut_config"; fi
  case "$state" in
    /var/lib/bbrv3-installer) rm -rf -- "$state" ;;
  esac
  printf '已恢复：下次开机进入官方内核 %s。现在运行的仍是 %s，重启后生效。\n' "$target" "$(uname -r)"
  if [[ "$reboot_after" == true ]]; then systemctl reboot; fi
  exit 0
fi

[[ "$mode" == install ]] ||
  die 'Usage: install-bbrv3.sh install [--reboot] [--allow-no-fallback] [--no-boot-once] | test | status | add-fallback | clean | restore'
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
  if command -v mokutil >/dev/null; then
    # mokutil fails, saying so, on firmware without Secure Boot.
    sb="$(mokutil --sb-state 2>&1 || true)"
  else
    # Read what mokutil reads: four attribute bytes, then 1 while Secure
    # Boot is enforced. Firmware without Secure Boot has no such variable.
    sb_variable=/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c
    if [[ -r "$sb_variable" ]]; then
      case "$(od -An -t u1 -j 4 -N 1 "$sb_variable" | tr -d '[:space:]')" in
        0) sb='SecureBoot disabled' ;;
        1) sb='SecureBoot enabled' ;;
        *) sb='' ;;
      esac
    elif [[ -n "$(ls -A /sys/firmware/efi/efivars 2>/dev/null)" ]]; then
      sb="This system doesn't support Secure Boot"
    else
      sb=''
    fi
  fi
  # Firmware without Secure Boot boots an unsigned kernel just as firmware
  # with Secure Boot turned off does.
  if grep -qi 'SecureBoot enabled' <<<"$sb"; then
    die 'Unsigned release requires Secure Boot disabled; signed installations need a separate procedure.'
  elif ! grep -Eqi "SecureBoot disabled|doesn't support Secure Boot" <<<"$sb"; then
    die "Cannot determine Secure Boot state.${sb:+ mokutil said: $sb}"
  fi
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

fallback_release="$(find_fallback_release "$expected" || true)"
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
# Let initramfs images built from now on, starting with the new kernel's,
# carry sch_fq and tcp_bbr.
if [[ -d /etc/dracut.conf.d ]] || command -v dracut >/dev/null; then
  if [[ ! -e "$dracut_config" ]]; then
    install -d /etc/dracut.conf.d
    printf '%s\n' "$dracut_line" > "$dracut_config"
  elif [[ "$(cat "$dracut_config")" != "$dracut_line" ]]; then
    printf 'NOTE: %s has other content and is left unchanged.\n' "$dracut_config"
  fi
fi
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
