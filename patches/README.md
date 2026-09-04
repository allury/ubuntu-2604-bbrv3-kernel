# BBRv3 patch policy

`bbrv3-ubuntu-7.0.0-30.30.patch` is a full TCP-stack port, not an
out-of-tree `tcp_bbr.ko` module.  It changes the TCP core and BBR
implementation together.

It was normalized to LF line endings and validated with:

```text
Ubuntu source tag: Ubuntu-7.0.0-30.30
git apply --check --whitespace=error
SHA-256: e4bd6d0b992a94c315caf85ff91b2851909f148337327714277df1970b292039
```

The port baseline is derived from the Linux 7.0 BBRv3 port in
[`byJoey/Actions-bbr-v3`](https://github.com/byJoey/Actions-bbr-v3) at
commit `d6bd606b74a64e0242ce7d1079c73bea2818743c`, and must remain
compatible with the official [Google BBR v3](https://github.com/google/bbr/tree/v3)
implementation.

The workflow deliberately uses exact `git apply --check` validation.  It
does not use fuzzy patching for TCP-core changes.  When a later Ubuntu kernel
source version needs a real port, add a new versioned patch here after review.
