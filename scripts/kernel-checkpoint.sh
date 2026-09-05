#!/usr/bin/env bash
set -euo pipefail
mode="${1:?Expected save or restore}"
: "${CHECKPOINT_PASSPHRASE:?Missing checkpoint encryption secret}"
: "${SOURCE_VERSION:?}" "${KERNEL_RELEASE:?}" "${PACKAGE_VERSION:?}" "${BBRV3_PATCH_SHA256:?}"
metadata="$(printf '%s\n' "$SOURCE_VERSION" "$KERNEL_RELEASE" "$PACKAGE_VERSION" "$BBRV3_PATCH_SHA256")"
mkdir -p checkpoint
case "$mode" in
  save)
    cp -- ./*.deb checkpoint/
    printf '%s\n' "$metadata" > kernel/.checkpoint-metadata
    # Only staged headers and the tools needed for DKMS, never the full objects.
    (
      cd kernel
      shopt -s nullglob
      paths=(debian/linux-headers-* debian/linux-lib-rust-*)
      tar -czf - .checkpoint-metadata "${paths[@]}" debian/scripts debian.master/changelog \
        debian/build/build-generic/.config debian/build/build-generic/scripts/sign-file \
        debian/build/build-generic/certs/signing_key.pem \
        debian/build/build-generic/certs/signing_key.x509
    ) | gpg --batch --yes --pinentry-mode loopback --passphrase-fd 3 \
      --symmetric --cipher-algo AES256 --output checkpoint/kernel-state.tar.gz.gpg \
      3<<<"$CHECKPOINT_PASSPHRASE"
    (cd checkpoint && sha256sum -- *.deb kernel-state.tar.gz.gpg > SHA256SUMS)
    ;;
  restore)
    (cd checkpoint && sha256sum --check --strict SHA256SUMS)
    archive="$(mktemp)"
    trap 'rm -f "$archive"' EXIT
    gpg --batch --yes --pinentry-mode loopback --passphrase-fd 3 \
      --output "$archive" --decrypt checkpoint/kernel-state.tar.gz.gpg \
      3<<<"$CHECKPOINT_PASSPHRASE"
    test "$(tar -xOzf "$archive" .checkpoint-metadata)" = "$metadata"
    tar -xzf "$archive" -C kernel
    cp -- checkpoint/*.deb .
    for package in ./*.deb; do
      test "$(dpkg-deb -f "$package" Version)" = "$PACKAGE_VERSION"
    done
    ;;
  *) echo 'Expected save or restore' >&2; exit 1 ;;
esac
