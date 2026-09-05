#!/usr/bin/env bash
set -euo pipefail

kernel_tree="${1:?Usage: build-zfs-package.sh <kernel-tree> <output-dir> <kernel-release> <package-version>}"
output_dir="${2:?Usage: build-zfs-package.sh <kernel-tree> <output-dir> <kernel-release> <package-version>}"
kernel_release="${3:?Usage: build-zfs-package.sh <kernel-tree> <output-dir> <kernel-release> <package-version>}"
package_version="${4:?Usage: build-zfs-package.sh <kernel-tree> <output-dir> <kernel-release> <package-version>}"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[[ -d "$kernel_tree" ]] || die "Kernel tree does not exist: $kernel_tree"
[[ -d "$output_dir" ]] || die "Output directory does not exist: $output_dir"
[[ "$kernel_release" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-generic$ ]] ||
  die "Unexpected kernel release: $kernel_release"
[[ "$package_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+\.[0-9]+(\.[0-9]+)*\+bbrv3\.[1-9][0-9]*$ ]] ||
  die "Unexpected package version: $package_version"

for tool in apt-cache apt-get dkms dpkg-deb dpkg-parsechangelog fakeroot md5sum modinfo sha256sum zstd; do
  command -v "$tool" >/dev/null || die "Missing build prerequisite: $tool"
done

kernel_tree="$(realpath "$kernel_tree")"
output_dir="$(realpath "$output_dir")"
abi_release="${kernel_release%-generic}"
common_headers="$kernel_tree/debian/linux-headers-$abi_release/usr/src/linux-headers-$abi_release"
flavour_headers="$kernel_tree/debian/linux-headers-$kernel_release/usr/src/linux-headers-$kernel_release"
build_dir="$kernel_tree/debian/build/build-generic"
sign_file="$build_dir/scripts/sign-file"
signing_key="$build_dir/certs/signing_key.pem"
signing_certificate="$build_dir/certs/signing_key.x509"

[[ -d "$common_headers" ]] || die "Missing staged common headers: $common_headers"
[[ -d "$flavour_headers" ]] || die "Missing staged flavour headers: $flavour_headers"
[[ -x "$sign_file" ]] || die "Missing kernel module signer: $sign_file"
[[ -s "$signing_key" ]] || die "Missing kernel module signing key: $signing_key"
[[ -s "$signing_certificate" ]] || die "Missing kernel module signing certificate: $signing_certificate"
grep -Fxq 'CONFIG_MODULE_SIG=y' "$build_dir/.config" ||
  die 'The custom kernel does not enable module signatures.'

work_dir="$(mktemp -d "$kernel_tree/debian/build/bbrv3-zfs.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
dkms_dir="$work_dir/dkms"
package_root="$work_dir/package"
module_parent="$package_root/usr/lib/modules/$kernel_release/ubuntu/dkms"
package_name="linux-main-modules-zfs-$kernel_release"
mkdir -p "$dkms_dir/headers" "$module_parent" "$package_root/DEBIAN"
cp -a "$common_headers" "$flavour_headers" "$dkms_dir/headers/"

zfs_candidate="$(apt-cache policy zfs-dkms | awk '/^[[:space:]]*Candidate:/ {print $2; exit}')"
[[ -n "$zfs_candidate" && "$zfs_candidate" != '(none)' ]] ||
  die 'Ubuntu APT metadata has no zfs-dkms candidate.'
(
  cd "$dkms_dir"
  apt-get download "zfs-dkms=$zfs_candidate"
)
mapfile -t zfs_debs < <(find "$dkms_dir" -maxdepth 1 -type f -name 'zfs-dkms_*.deb' -print | sort)
(( ${#zfs_debs[@]} == 1 )) || die "Expected exactly one zfs-dkms package, found ${#zfs_debs[@]}."
zfs_deb="${zfs_debs[0]}"
zfs_binary_name="$(dpkg-deb -f "$zfs_deb" Package)"
zfs_source_name="$(dpkg-deb -f "$zfs_deb" Source | awk '{print $1}')"
zfs_source_version="$(dpkg-deb -f "$zfs_deb" Version)"
[[ "$zfs_binary_name" == zfs-dkms ]] || die "Downloaded unexpected package: $zfs_binary_name"
[[ "$zfs_source_name" == zfs-linux ]] || die "zfs-dkms came from unexpected source: $zfs_source_name"
[[ "$zfs_source_version" == "$zfs_candidate" ]] ||
  die "Downloaded zfs-dkms $zfs_source_version, expected APT candidate $zfs_candidate"

sign_command="$sign_file sha512 $signing_key $signing_certificate"
(
  cd "$kernel_tree"
  env ARCH=x86 CROSS_COMPILE='' ./debian/scripts/dkms-build \
    "$dkms_dir" \
    "$kernel_release" \
    "$sign_command" \
    "$package_name" \
    "$module_parent" \
    '' \
    zfs \
    "zfs-dkms=$zfs_source_version"
)

module_dir="$module_parent/zfs"
[[ -d "$module_dir" ]] || die "ZFS build did not create $module_dir"
for module_name in spl zfs; do
  module_path="$module_dir/$module_name.ko"
  [[ -s "$module_path" ]] || die "ZFS build did not produce $module_name.ko"
  module_vermagic="$(modinfo -F vermagic "$module_path")"
  [[ "${module_vermagic%% *}" == "$kernel_release" ]] ||
    die "$module_name vermagic does not match $kernel_release: $module_vermagic"
  [[ -n "$(modinfo -F signer "$module_path")" ]] ||
    die "$module_name is not signed with the custom kernel build key"
  zstd -19 --quiet --rm "$module_path"
done

doc_dir="$package_root/usr/share/doc/$package_name"
mkdir -p "$doc_dir"
zfs_extract_dir="$dkms_dir/zfs"
build_date="$(dpkg-parsechangelog -l "$kernel_tree/debian.master/changelog" -S Date)"
[[ -f "$zfs_extract_dir/usr/share/doc/zfs-dkms/copyright" ]] ||
  die 'The Ubuntu zfs-dkms package did not contain its copyright file.'
cp "$zfs_extract_dir/usr/share/doc/zfs-dkms/copyright" "$doc_dir/copyright"
{
  printf '%s (%s) resolute; urgency=medium\n\n' "$package_name" "$package_version"
  printf '%s\n' '  * Build Ubuntu OpenZFS modules for the matching BBRv3 custom ABI.'
  printf '\n -- allury <allury@users.noreply.github.com>  %s\n' "$build_date"
} | gzip -9n > "$doc_dir/changelog.Debian.gz"

installed_size="$(du -sk "$package_root/usr" | awk '{print $1}')"
cat > "$package_root/DEBIAN/control" <<EOF
Package: $package_name
Source: ubuntu-bbrv3-kernel
Version: $package_version
Architecture: amd64
Maintainer: allury <allury@users.noreply.github.com>
Installed-Size: $installed_size
Depends: kmod, linux-image-$kernel_release | linux-image-unsigned-$kernel_release
Provides: spl-dkms, spl-modules, zfs-dkms, zfs-modules
Built-Using: zfs-linux (= $zfs_source_version)
Section: kernel
Priority: optional
Description: Locally signed ZFS modules for $kernel_release
 This package contains Ubuntu OpenZFS modules built and locally signed for
 the exact BBRv3 custom kernel ABI. It is not signed by Canonical.
EOF

cat > "$package_root/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e

version=@KERNEL_RELEASE@
image_path=/boot/vmlinuz-$version

if [ "$1" != configure ]; then
    exit 0
fi

depmod -a -F /boot/System.map-$version $version || true
if [ -d /etc/kernel/postinst.d ]; then
    mkdir -p /usr/lib/linux/triggers
    cat - >/usr/lib/linux/triggers/$version <<TRIGGER
DEB_MAINT_PARAMS="$*" run-parts --report --exit-on-error --arg=$version \\
        --arg="$image_path" /etc/kernel/postinst.d
TRIGGER
    dpkg-trigger --no-await linux-update-$version
fi

exit 0
EOF

cat > "$package_root/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e

version=@KERNEL_RELEASE@

if [ "$1" != remove ]; then
    exit 0
fi

depmod -a -F /boot/System.map-$version $version 2>/dev/null || true
exit 0
EOF

sed -i "s/@KERNEL_RELEASE@/$kernel_release/g" \
  "$package_root/DEBIAN/postinst" "$package_root/DEBIAN/postrm"
chmod 0755 "$package_root/DEBIAN/postinst" "$package_root/DEBIAN/postrm"
(
  cd "$package_root"
  find usr -type f -print0 | sort -z | xargs -0 md5sum > DEBIAN/md5sums
)

output_package="$output_dir/${package_name}_${package_version}_amd64.deb"
dpkg-deb --build --root-owner-group -Zzstd -z19 "$package_root" "$output_package"

{
  printf 'ZFS source binary: %s\n' "$(basename "$zfs_deb")"
  printf 'ZFS source package: %s\n' "$zfs_source_name"
  printf 'ZFS source version: %s\n' "$zfs_source_version"
  printf 'ZFS source binary SHA256: %s\n' "$(sha256sum "$zfs_deb" | awk '{print $1}')"
  printf 'ZFS modules: spl.ko.zst, zfs.ko.zst\n'
  printf 'ZFS package: %s\n' "$(basename "$output_package")"
} > "$output_dir/ZFS-BUILD-METADATA.txt"

printf 'Built %s from Ubuntu zfs-dkms %s.\n' "$output_package" "$zfs_source_version"
