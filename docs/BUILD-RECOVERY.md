# Recovering a kernel build

The workflow compiles and packages Ubuntu ZFS against the exact released
official headers before starting the full kernel build. This preflight also
exercises encrypted checkpoint save and restore. It does not replace tests
against the custom kernel and its headers.

After the core build succeeds, `core-checkpoint` is uploaded before ZFS starts.
It contains the core Debian packages, checksums and an encrypted archive of
the staged headers, DKMS tools, kernel configuration and module signing key.
The archive uses GnuPG authenticated symmetric encryption with the repository
secret `KERNEL_CHECKPOINT_PASSPHRASE`. Preserve this secret while recovery
artifacts are needed. Never upload plaintext signing keys.

To continue after a ZFS or verification failure:

1. Confirm the failed run has a non-expired `core-checkpoint` artifact.
2. Fix the failing ZFS or verification code on `main`.
3. Dispatch `build-kernel.yml`, select the same explicit `source_version`, set
   `resume_run_id` to the run containing the checkpoint and leave
   `preflight_only` false.
4. The workflow reruns the ZFS preflight, fetches the exact source and patch,
   validates and decrypts the checkpoint, skips full kernel compilation, then
   rebuilds ZFS and runs installation and QEMU gates before publishing.

Only reuse checkpoints when core kernel source, patch and packaging inputs are
unchanged. Changing the kernel configuration, ABI scheme or core build logic
requires a new build. Source version, release, package version and BBR patch
digest are checked during restoration. Recovery does not bypass publishing
gates and does not make incomplete packages a stable release.

`preflight_only=true` runs the inexpensive integration check without compiling
the full kernel. Failed runs from before checkpoint support cannot be resumed.
Recovery is available only until the artifact expires; when retention is one
day, recover within that window. GitHub's ordinary rerun of a failed build job
does not automatically select a checkpoint: use `resume_run_id` explicitly.
