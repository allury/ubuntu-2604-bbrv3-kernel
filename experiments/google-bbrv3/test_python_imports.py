"""Detect stdlib shadowing before fetching or compiling the kernel."""
import pathlib
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parent
collisions = sorted(p.name for p in root.glob("*.py")
                    if p.stem in sys.stdlib_module_names)
if collisions:
    raise SystemExit("Standard-library module shadowed: " + ", ".join(collisions))
subprocess.run([sys.executable, "-c",
                "import argparse, dataclasses, inspect; "
                "assert callable(inspect.signature); "
                "argparse.ArgumentParser().format_help()"],
               cwd=root, check=True)
for script in ("inspect_sources.py", "verify_series.py", "network_matrix.py"):
    subprocess.run([sys.executable, str(root / script), "--help"],
                   check=True, stdout=subprocess.DEVNULL, timeout=15)
print("PASS: no stdlib name collisions and all CLI imports/help work")
