# Ubuntu 26.04 BBRv3 kernel

This repository builds a complete Ubuntu 26.04 **amd64** generic kernel with
Google BBRv3's TCP-core changes.  It does **not** package BBRv3 as an
out-of-tree `tcp_bbr.ko` module.

The initial target is the Ubuntu source package `linux 7.0.0-30.30`, which
corresponds to the installed kernel ABI `7.0.0-30-generic`.  The resulting
custom kernel is intentionally named `7.0.0-10030-generic`, so it can remain
installed alongside Canonical's `7.0.0-30-generic` fallback.

## What the workflow does

1. Resolves the requested or newest Ubuntu 26.04 `7.0.0-*` linux source tag.
2. Clones that exact Launchpad source tag.
3. Applies the full BBRv3 TCP-stack patch and verifies it with exact
   `git apply --check`.
4. Uses Ubuntu's native packaging rules to build image, modules, and headers
   Debian packages.
5. Checks that `tcp_bbr.ko` and `fq` are enabled, then publishes the
   packages and SHA-256 checksums in a GitHub Release.

The daily schedule detects a newly published Ubuntu source ABI and builds it
automatically **only when the BBRv3 patch validates exactly**.  If a kernel
update changes relevant TCP code, the workflow fails closed and opens a
porting issue instead of publishing an unsafe binary.  No CI design can
honestly promise a correct BBRv3 port across arbitrary future kernel changes
without this guardrail.

## First build

Open **Actions → Build Ubuntu 26.04 BBRv3 kernel → Run workflow** and keep the
default `7.0.0-30.30`.  The full build can take a long time and needs
substantial GitHub Actions disk and minutes.

## Install on the server

Download all `.deb` assets for one release to an empty directory on the
Ubuntu 26.04 amd64 server, verify them, and install them together:

```bash
sha256sum -c SHA256SUMS
sudo apt install ./linux-headers-*.deb ./linux-modules-*.deb ./linux-image-unsigned-*.deb
sudo update-grub
sudo reboot
```

After reboot, preserve the vendor kernel as a GRUB fallback and check that the
custom kernel is running:

```bash
uname -r
# expected initial result: 7.0.0-10030-generic
modinfo -F version tcp_bbr
# expected: 3
```

Then copy `config/bbrv3.sysctl.conf` to
`/etc/sysctl.d/99-bbrv3.conf` and enable it:

```bash
sudo modprobe tcp_bbr
sudo install -m 0644 config/bbrv3.sysctl.conf /etc/sysctl.d/99-bbrv3.conf
sudo sysctl --system
sysctl net.ipv4.tcp_congestion_control
cat /proc/sys/net/ipv4/tcp_available_congestion_control
```

BBRv3 is selected with `bbr`, not `bbr3`; this is the congestion-control
algorithm name exported by the official implementation.

The packages are intentionally unsigned.  Do not try to boot them with Secure
Boot enabled unless you first sign them and enroll the signing key through
MOK.  Disabling Secure Boot or setting up a local signing flow is required.

## Patch provenance

The BBRv3 implementation is based on the official
[Google BBR v3 branch](https://github.com/google/bbr/tree/v3).  The initial
Linux 7.0 port baseline is documented in [`patches/README.md`](patches/README.md).
The vendored patch has LF line endings and was checked against the exact
`Ubuntu-7.0.0-30.30` source tag before being included here.
