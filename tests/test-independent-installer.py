"""Exercise the actual embedded shell branches without installing or rebooting."""
import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
TEXT = (ROOT / "installer/install.sh").read_text()
INNER = TEXT.split("<<'BBRV3_INSTALLER_V1'\n", 1)[1].split("\nBBRV3_INSTALLER_V1", 1)[0]


def bash(code, *args):
    return subprocess.run(["bash", "-c", "set -euo pipefail\n" + code, "_", *args],
                          capture_output=True, text=True, timeout=10)


class InstallerTests(unittest.TestCase):
    def test_syntax(self):
        subprocess.run(["bash", "-n", str(ROOT / "installer/install.sh")], check=True)

    def test_options(self):
        parser = INNER.split("allow_no_fallback=false", 1)[1].split("# shellcheck source=", 1)[0]
        code = "die() { exit 19; }; allow_no_fallback=false" + parser
        code += '\nprintf "%s %s" "$allow_no_fallback" "$reboot_requested"'
        for options, expected in [
            ([], "false false"), (["--reboot"], "false true"),
            (["--allow-no-fallback"], "true false"),
            (["--allow-no-fallback", "--reboot"], "true true"),
            (["--reboot", "--allow-no-fallback"], "true true"),
        ]:
            result = bash(code, "install", *options)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, expected)
        self.assertNotEqual(bash(code, "install", "--invalid").returncode, 0)

    def test_outer_forwards_options(self):
        parser = TEXT.split("requested_tag='latest'", 1)[1].split('if [[ "$requested_tag" != latest ]]', 1)[0]
        result = bash("die() { exit 19; }; requested_tag=latest" + parser +
                      '\nprintf "%s " "$requested_tag" "${install_options[@]}"',
                      "--tag", "ubuntu-26.04-bbrv3-7.0.0-30.30-p2",
                      "--allow-no-fallback", "--reboot")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout,
                         "ubuntu-26.04-bbrv3-7.0.0-30.30-p2 --allow-no-fallback --reboot ")

    def test_fallback_gate(self):
        gate = 'if [[ -z "$fallback_release" ]]; then' + INNER.split(
            'if [[ -z "$fallback_release" ]]; then', 1)[1].split("mounted_zfs=", 1)[0]
        for fallback, allow, success in [
            ("", "false", False), ("", "true", True),
            ("7.0.0-30-generic", "false", True),
            ("7.0.0-30-generic", "true", True),
        ]:
            result = bash('die() { exit 19; }; fallback_release="$1"; allow_no_fallback="$2"\n' +
                          gate, fallback, allow)
            self.assertEqual(result.returncode == 0, success, result.stderr)
            if not fallback and allow == "true":
                self.assertIn("rescue console", result.stderr)

    def test_package_checks_preserved(self):
        self.assertIn("sha256sum --check --strict SHA256SUMS", INNER)
        self.assertIn('apt-get --simulate --no-remove install "${packages[@]}"', INNER)
        self.assertIn("Repair the existing dpkg state", INNER)
        self.assertIn("SecureBoot disabled", INNER)
        self.assertNotIn("raw.githubusercontent.com", TEXT)
        self.assertNotIn("--force-depends", TEXT)
        self.assertIn('if [[ "$reboot_requested" == true ]]; then systemctl reboot; fi', INNER)


if __name__ == "__main__":
    unittest.main()
