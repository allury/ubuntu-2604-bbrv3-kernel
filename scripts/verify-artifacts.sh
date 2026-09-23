#!/usr/bin/env bash
set -euo pipefail

release_dir="${1:?Usage: verify-artifacts.sh <release-dir> <kernel-release> <package-version> <source-version>}"
kernel_release="${2:?Usage: verify-artifacts.sh <release-dir> <kernel-release> <package-version> <source-version>}"
package_version="${3:?Usage: verify-artifacts.sh <release-dir> <kernel-release> <package-version> <source-version>}"
source_version="${4:?Usage: verify-artifacts.sh <release-dir> <kernel-release> <package-version> <source-version>}"
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ -d "$release_dir" ]] || die "Release directory does not exist: $release_dir"
[[ "$kernel_release" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-generic$ ]] ||
  die "Unexpected custom kernel release: $kernel_release"
[[ "$package_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+\.[0-9]+(\.[0-9]+)*\+bbrv3\.[1-9][0-9]*$ ]] ||
  die "Unexpected package version: $package_version"
[[ "$source_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+\.[0-9]+(\.[0-9]+)*$ ]] ||
  die "Unexpected Ubuntu source version: $source_version"

abi_release="${kernel_release%-generic}"
required_image="linux-image-unsigned-$kernel_release"
required_modules="linux-modules-$kernel_release"
required_flavour_headers="linux-headers-$kernel_release"
required_common_headers="linux-headers-$abi_release"
required_buildinfo="linux-buildinfo-$kernel_release"
required_zfs="linux-main-modules-zfs-$kernel_release"
optional_rust="linux-lib-rust-$kernel_release"

mapfile -t packages < <(find "$release_dir" -maxdepth 1 -type f -name '*.deb' -printf '%f\n' | sort)
(( ${#packages[@]} > 0 )) || die "No .deb artifacts found."

declare -A package_paths=()
declare -A expected_architectures=(
  ["$required_image"]=amd64
  ["$required_modules"]=amd64
  ["$required_flavour_headers"]=amd64
  ["$required_common_headers"]=all
  ["$required_buildinfo"]=amd64
  ["$required_zfs"]=amd64
  ["$optional_rust"]=amd64
)
manifest_tmp="$(mktemp)"
unpack_dir="$(mktemp -d)"
module_listing="$(mktemp)"
zfs_listing="$(mktemp)"
trap 'rm -f "$manifest_tmp" "$module_listing" "$zfs_listing"; rm -rf "$unpack_dir"' EXIT

printf 'File\tPackage\tVersion\tArchitecture\tSHA256\n' > "$manifest_tmp"
for package_name in "${packages[@]}"; do
  package_path="$release_dir/$package_name"
  deb_name="$(dpkg-deb -f "$package_path" Package)"
  deb_version="$(dpkg-deb -f "$package_path" Version)"
  deb_arch="$(dpkg-deb -f "$package_path" Architecture)"
  [[ "$deb_name" != *dbgsym* ]] || die "Debug symbol package was produced: $deb_name"
  [[ "$deb_version" == "$package_version" ]] ||
    die "Unexpected package version in $package_name: $deb_version"
  [[ -n "${expected_architectures[$deb_name]:-}" ]] ||
    die "Unexpected package was produced: $deb_name"
  expected_arch="${expected_architectures[$deb_name]}"
  [[ "$deb_arch" == "$expected_arch" ]] ||
    die "Unexpected architecture in $package_name: $deb_arch (expected $expected_arch)"
  [[ -z "${package_paths[$deb_name]:-}" ]] || die "Duplicate package: $deb_name"

  package_paths["$deb_name"]="$package_path"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$package_name" "$deb_name" "$deb_version" "$deb_arch" \
    "$(sha256sum "$package_path" | awk '{print $1}')" >> "$manifest_tmp"
done

for required_package in \
  "$required_image" \
  "$required_modules" \
  "$required_flavour_headers" \
  "$required_common_headers" \
  "$required_buildinfo" \
  "$required_zfs"; do
  [[ -n "${package_paths[$required_package]:-}" ]] ||
    die "Required package was not produced: $required_package"
done

image_depends="$(dpkg-deb -f "${package_paths[$required_image]}" Depends)"
grep -Fq "$required_modules" <<<"$image_depends" ||
  die "$required_image does not depend on $required_modules"
flavour_headers_depends="$(dpkg-deb -f "${package_paths[$required_flavour_headers]}" Depends)"
grep -Fq "$required_common_headers" <<<"$flavour_headers_depends" ||
  die "$required_flavour_headers does not depend on $required_common_headers"

modules_depends="$(dpkg-deb -f "${package_paths[$required_modules]}" Depends)"
grep -Fq "$required_zfs" <<<"$modules_depends" ||
  die "$required_modules does not depend on $required_zfs"
grep -Fq 'wireless-regdb' <<<"$modules_depends" ||
  die "$required_modules unexpectedly lacks its wireless-regdb dependency"

zfs_depends="$(dpkg-deb -f "${package_paths[$required_zfs]}" Depends)"
grep -Fq 'kmod' <<<"$zfs_depends" || die "$required_zfs does not depend on kmod"
grep -Fq "linux-image-$kernel_release | linux-image-unsigned-$kernel_release" <<<"$zfs_depends" ||
  die "$required_zfs does not depend on the matching signed or unsigned image"
zfs_provides="$(dpkg-deb -f "${package_paths[$required_zfs]}" Provides)"
for provided_name in spl-dkms spl-modules zfs-dkms zfs-modules; do
  grep -Fwq "$provided_name" <<<"${zfs_provides//,/ }" ||
    die "$required_zfs does not provide $provided_name"
done

modules_package="${package_paths[$required_modules]}"
dpkg-deb -c "$modules_package" > "$module_listing"
if ! grep -E "/usr/lib/modules/$kernel_release/kernel/net/ipv4/tcp_bbr\\.ko(\\.(xz|zst))?$" "$module_listing" >/dev/null; then
  die "BBR module is missing from the modules package."
fi

dpkg-deb -x "$modules_package" "$unpack_dir"
module_path="$(find "$unpack_dir/usr/lib/modules/$kernel_release" -type f -name 'tcp_bbr.ko*' -print -quit)"
[[ -n "$module_path" ]] || die "Unable to extract tcp_bbr from the modules package."

module_version="$(modinfo -F version "$module_path" || true)"
[[ "$module_version" == "3" ]] ||
  die "tcp_bbr module is not BBRv3 (modinfo version: ${module_version:-missing})"
module_vermagic="$(modinfo -F vermagic "$module_path" || true)"
[[ "${module_vermagic%% *}" == "$kernel_release" ]] ||
  die "tcp_bbr vermagic does not match $kernel_release: ${module_vermagic:-missing}"

zfs_package="${package_paths[$required_zfs]}"
dpkg-deb -c "$zfs_package" > "$zfs_listing"
for zfs_module_name in spl zfs; do
  if ! grep -E "/usr/lib/modules/$kernel_release/ubuntu/dkms/zfs/$zfs_module_name\\.ko(\\.(xz|zst))?$" "$zfs_listing" >/dev/null; then
    die "$zfs_module_name is missing from $required_zfs"
  fi
done
dpkg-deb -x "$zfs_package" "$unpack_dir"
for zfs_module_name in spl zfs; do
  zfs_module_path="$(find "$unpack_dir/usr/lib/modules/$kernel_release" -type f -name "$zfs_module_name.ko*" -print -quit)"
  [[ -n "$zfs_module_path" ]] || die "Unable to extract $zfs_module_name from $required_zfs"
  zfs_vermagic="$(modinfo -F vermagic "$zfs_module_path" || true)"
  [[ "${zfs_vermagic%% *}" == "$kernel_release" ]] ||
    die "$zfs_module_name vermagic does not match $kernel_release: ${zfs_vermagic:-missing}"
  [[ -n "$(modinfo -F signer "$zfs_module_path" || true)" ]] ||
    die "$zfs_module_name is not signed with the custom kernel build key"
done
[[ -n "$(modinfo -F version "$(find "$unpack_dir/usr/lib/modules/$kernel_release" -type f -name 'zfs.ko*' -print -quit)" || true)" ]] ||
  die 'The packaged OpenZFS module does not declare a version.'

# The release notes state that the shipped patch is the approved one, so check
# the file that is actually shipped rather than trusting an earlier step.
mapfile -t release_patches < <(find "$release_dir" -maxdepth 1 -type f -name '*.patch' -printf '%f\n')
(( ${#release_patches[@]} == 1 )) ||
  die "Expected exactly one BBRv3 patch in the release, found ${#release_patches[@]}."
patch_name="${release_patches[0]}"
patch_sha256="$(sha256sum "$release_dir/$patch_name" | awk '{print $1}')"
mapfile -t approved_sha256 < <(
  awk -v target="$patch_name" '{ name = $2; sub(/^\*/, "", name) } name == target { print $1 }' \
    "$repo_root/patches/APPROVED-SHA256SUMS"
)
(( ${#approved_sha256[@]} == 1 )) ||
  die "$patch_name needs exactly one entry in patches/APPROVED-SHA256SUMS; found ${#approved_sha256[@]}."
[[ "${approved_sha256[0]}" == "$patch_sha256" ]] ||
  die "$patch_name does not match its approved SHA-256 in patches/APPROVED-SHA256SUMS."

drift_report="$release_dir/PATCH-BASELINE-DRIFT.txt"
[[ -s "$drift_report" ]] || die "Missing patch baseline drift report: $drift_report"
drift_field() {
  awk -v key="$1: " 'index($0, key) == 1 { print substr($0, length(key) + 1); exit }' "$drift_report"
}
[[ "$(drift_field Patch)" == "$patch_name" ]] || die "The drift report does not describe $patch_name."
[[ "$(drift_field 'Built source')" == "Ubuntu-$source_version" ]] ||
  die "The drift report does not describe Ubuntu-$source_version."
drift_baseline="$(drift_field 'Review baseline')"
[[ "$drift_baseline" =~ ^Ubuntu-[0-9]+\.[0-9]+\.[0-9]+-[0-9]+\.[0-9]+(\.[0-9]+)*$ ]] ||
  die "Unexpected review baseline in the drift report: ${drift_baseline:-missing}"
drift_changed="$(drift_field 'Changed since baseline')"
drift_added="$(drift_field 'Lines added')"
drift_removed="$(drift_field 'Lines removed')"
for drift_count in "$drift_changed" "$drift_added" "$drift_removed"; do
  [[ "$drift_count" =~ ^[0-9]+$ ]] || die "Malformed count in the drift report: ${drift_count:-missing}"
done

mv "$manifest_tmp" "$release_dir/PACKAGE-MANIFEST.tsv"
(
  cd "$release_dir"
  sha256sum -- *.deb > SHA256SUMS
)

{
  printf '%s\n\n' '# Ubuntu 26.04 BBRv3 内核'
  printf '%s\n' "- Ubuntu 源码包：linux $source_version"
  printf '%s\n' "- 自定义内核版本：$kernel_release"
  printf '%s\n' "- 软件包版本：$package_version"
  printf '%s\n' '- 启动后的拥塞控制名称：bbr（不是 bbr3）'
  printf '%s\n' '- 已从软件包验证 BBR 模块版本：3'
  printf '%s\n' "- BBRv3 补丁：$patch_name，SHA-256 与仓库中维护者批准的值一致（patches/APPROVED-SHA256SUMS）"
  if (( drift_changed == 0 )); then
    printf '%s\n\n' "- 补丁涉及的文件相对审核基线 $drift_baseline 没有变化"
  else
    printf '%s\n\n' "- 补丁涉及的文件相对审核基线 $drift_baseline 有 $drift_changed 个发生变化（+$drift_added/-$drift_removed 行），详见附件 PATCH-BASELINE-DRIFT.txt；补丁能精确应用不代表这些变化已经过人工审核"
  fi
  printf '%s\n\n' '本发布仅在完整构建、干净环境安装检查、QEMU 启动冒烟测试，以及 Ubuntu 26.04 云镜像虚拟机中的安装与重启验收通过后生成；这些检查不代表所有硬件、服务商引导配置和网络场景均已验证。'
  printf '%s\n' '自定义内核可与 Canonical 官方内核共存，请保留官方内核作为回退。'
  printf '%s\n' "包含配套的 $required_zfs 软件包，已验证本地签名的 spl/zfs 模块及其 vermagic 与目标内核匹配。"
  printf '%s\n\n' '内核镜像未经 Canonical 签名。使用 Secure Boot 需另行签名并注册信任，否则应关闭 Secure Boot。'
  printf '%s\n\n' '## 安装'
  printf '%s\n\n' '一键安装器独立版本化，不随内核自动构建更新。安装命令及无回退内核时的显式选项见 [项目安装说明](https://github.com/allury/ubuntu-2604-bbrv3-kernel#安装)。'
  printf '%s\n' '独立安装器默认选择最新正式内核。如需固定本版本，请追加 --tag 参数，并填写本发布页的完整标签。'
  printf '%s\n' '内核附件中的历史脚本为兼容现有校验流程而保留，不是独立安装器的新版本。请使用项目安装说明中的独立入口。'
} > "$release_dir/RELEASE-NOTES.md"

printf 'Verified %d Debian packages for %s.\n' "${#packages[@]}" "$kernel_release"
