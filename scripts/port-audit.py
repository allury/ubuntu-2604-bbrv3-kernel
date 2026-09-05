#!/usr/bin/env python3
"""Multiset comparison of the self-ported tree against Google's v3 files."""
import collections
import pathlib
import sys

ported_root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "ported")
google_root = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else "google")

for rel in sorted(p for p in ported_root.rglob("*") if p.is_file()):
    r = str(rel.relative_to(ported_root))
    g = google_root / r
    if not g.exists():
        print(f"{r}: no google counterpart (expected for tcp_ecn.h routing)")
        continue
    a = collections.Counter(g.read_text().splitlines())
    b = collections.Counter(rel.read_text().splitlines())
    only_g = sum((a - b).values())
    only_p = sum((b - a).values())
    print(f"{r}: googleOnly={only_g} portOnly={only_p}")
