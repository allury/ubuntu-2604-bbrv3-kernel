#!/usr/bin/env bash
set -euo pipefail
: "${SOURCE_VERSION:?}" "${PACKAGE_VERSION:?}"
repo_root="$PWD"
# Extract the ABI from the already validated Ubuntu source version.
[[ "$SOURCE_VERSION" =~ ^([0-9]+\.[0-9]+\.[0-9]+)-([0-9]+)\. ]] || exit 1
official_release="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-generic"
abi_release="${official_release%-generic}"
mkdir -p preflight/download preflight/output
cd preflight/download
apt-get download "linux-headers-$abi_release=$SOURCE_VERSION" "linux-headers-$official_release=$SOURCE_VERSION"
for package in ./*.deb; do
  name="$(dpkg-deb -f "$package" Package)"
  dpkg-deb -x "$package" "$repo_root/kernel/debian/$name"
  dpkg-deb -x "$package" "$repo_root/preflight/installed"
done
cd "$repo_root"
build=kernel/debian/build/build-generic
mkdir -p "$build/scripts" "$build/certs"
headers="preflight/installed/usr/src/linux-headers-$official_release"
cp -L "$headers/scripts/sign-file" "$build/scripts/sign-file"
chmod +x "$build/scripts/sign-file"
printf 'CONFIG_MODULE_SIG=y\n' > "$build/.config"
openssl req -new -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj /CN=ZFS-preflight/ -keyout "$build/certs/signing_key.pem" \
  -outform DER -out "$build/certs/signing_key.x509"
bash scripts/build-zfs-package.sh "$repo_root/kernel" "$repo_root/preflight/output" \
  "$official_release" "$PACKAGE_VERSION" 2>&1 | tee preflight/zfs.log

# Exercise the actual encrypted save/restore path before spending time on a
# kernel build. This temporary test key is never a release signing key.
cp preflight/output/*.deb .
export CHECKPOINT_PASSPHRASE
CHECKPOINT_PASSPHRASE="$(openssl rand -hex 48)"
export KERNEL_RELEASE="$official_release" BBRV3_PATCH_SHA256=preflight-only
bash scripts/kernel-checkpoint.sh save
bash scripts/kernel-checkpoint.sh restore
printf '%s\n' 'ZFS_PACKAGE_AND_CHECKPOINT_PREFLIGHT_PASS'
