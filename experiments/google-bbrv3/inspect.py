"""Read-only source inspection; generated output is NOT a production patch."""
import argparse
import json
import pathlib
import subprocess

GOOGLE = "90210de4b779d40496dee0b89081780eeddf2a60"
BASE = "648e04a805652f513af04b47035cde896addf9b0"
UBUNTU = "d974a4063f5c03c13b4f241a9ab511750e0b9f12"


def git(repo, *args, check=True):
    # Disable partial-clone lazy fetches: inspection must not silently use network.
    import os
    env = dict(os.environ, GIT_NO_LAZY_FETCH="1", GIT_TERMINAL_PROMPT="0")
    return subprocess.run(
        ["git", "-c", "safe.directory=" + str(repo), "-C", str(repo), *args],
        check=check, capture_output=True, env=env)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("google", "ubuntu", "output"):
        parser.add_argument("--" + name, required=True, type=pathlib.Path)
    args = parser.parse_args()
    google, ubuntu, output = (p.resolve() for p in (args.google, args.ubuntu, args.output))
    for repo, commit in ((google, GOOGLE), (google, BASE), (ubuntu, UBUNTU)):
        git(repo, "cat-file", "-e", commit + "^{commit}")
    if git(google, "merge-base", BASE, GOOGLE).stdout.decode().strip() != BASE:
        raise SystemExit("Unexpected Google base")
    if git(ubuntu, "rev-parse", "HEAD").stdout.decode().strip() != UBUNTU:
        raise SystemExit("Ubuntu HEAD is not the pinned source")
    if git(ubuntu, "diff", "--cached", "--name-only", UBUNTU).stdout:
        raise SystemExit("Ubuntu index must exactly match the pinned source")
    delta = git(google, "diff", "--binary", "--full-index", BASE, GOOGLE, "--", "include/", "net/").stdout
    if not delta:
        raise SystemExit("Empty delta")
    output.mkdir(parents=True, exist_ok=False)
    patch = output / "official-kernel-delta.patch"
    patch.write_bytes(delta)
    (output / "commits.txt").write_bytes(git(google, "log", "--reverse", "--format=%H %s", BASE + ".." + GOOGLE).stdout)
    (output / "files.txt").write_bytes(git(google, "diff", "--stat", BASE, GOOGLE).stdout)
    # Check the pristine index, avoiding Windows case-colliding Linux filenames.
    result = git(ubuntu, "apply", "--cached", "--check", "--whitespace=error", str(patch), check=False)
    (output / "apply-check.txt").write_bytes(result.stdout + result.stderr)
    report = dict(google_commit=GOOGLE, linux_base=BASE, ubuntu_commit=UBUNTU,
                  exact_apply_exit_code=result.returncode, production_ready=False)
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
