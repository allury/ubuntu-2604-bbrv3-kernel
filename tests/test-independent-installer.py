"""Exercise the actual embedded shell branches without installing or rebooting."""
import os
import pathlib
import subprocess
import tempfile
import types
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
TEXT = (ROOT / "installer/install.sh").read_text()
INNER = TEXT.split("<<'BBRV3_INSTALLER_V1'\n", 1)[1].split("\nBBRV3_INSTALLER_V1", 1)[0]


def bash(code, *args):
    return subprocess.run(["bash", "-c", "set -euo pipefail\n" + code, "_", *args],
                          capture_output=True, text=True, timeout=10)


def grub_entry(entry_id, title, indent, release):
    inner = indent + "\t"
    return (f"{indent}menuentry '{title}' --class ubuntu $menuentry_id_option '{entry_id}' {{\n"
            f"{inner}recordfail\n"
            f"{inner}search --no-floppy --fs-uuid --set=root 1111\n"
            f"{inner}linux\t/boot/vmlinuz-{release} root=UUID=1111 ro console=ttyS0\n"
            f"{inner}initrd\t/boot/initrd.img-{release}\n"
            f"{indent}}}\n")


# The layout update-grub writes on Ubuntu: a top-level entry for the newest
# kernel, then every kernel and its recovery entry in a submenu.
GRUB_CFG = ("function gfxmode {\n\tset gfxpayload=\"${1}\"\n}\n"
            + grub_entry("gnulinux-simple-1111", "Ubuntu", "", "7.0.0-13402-generic")
            + "submenu 'Advanced options for Ubuntu' $menuentry_id_option 'gnulinux-advanced-1111' {\n"
            + grub_entry("gnulinux-7.0.0-13402-generic-advanced-1111",
                         "Ubuntu, with Linux 7.0.0-13402-generic", "\t", "7.0.0-13402-generic")
            + grub_entry("gnulinux-7.0.0-13402-generic-recovery-1111",
                         "Ubuntu, with Linux 7.0.0-13402-generic (recovery mode)", "\t",
                         "7.0.0-13402-generic")
            + grub_entry("gnulinux-7.0.0-31-generic-advanced-1111",
                         "Ubuntu, with Linux 7.0.0-31-generic", "\t", "7.0.0-31-generic")
            + "}\n")


class InstallerTests(unittest.TestCase):
    def test_syntax(self):
        subprocess.run(["bash", "-n", str(ROOT / "installer/install.sh")], check=True)

    def test_options(self):
        parser = INNER.split("allow_no_fallback=false", 1)[1].split("# shellcheck source=", 1)[0]
        code = "die() { exit 19; }; allow_no_fallback=false" + parser
        code += '\nprintf "%s %s %s" "$allow_no_fallback" "$reboot_requested" "$boot_once_requested"'
        for options, expected in [
            ([], "false false true"), (["--reboot"], "false true true"),
            (["--allow-no-fallback"], "true false true"),
            (["--allow-no-fallback", "--reboot"], "true true true"),
            (["--reboot", "--allow-no-fallback"], "true true true"),
            (["--no-boot-once"], "false false false"),
            (["--no-boot-once", "--reboot"], "false true false"),
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
                      "--allow-no-fallback", "--reboot", "--no-boot-once")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout,
                         "ubuntu-26.04-bbrv3-7.0.0-30.30-p2 --allow-no-fallback --reboot --no-boot-once ")

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
        # The trial boot is committed only by the post-boot verification,
        # which must run once the network is up.
        self.assertIn("After=network-online.target", INNER)
        self.assertIn('grub-set-default "$fallback_entry"', INNER)
        self.assertIn('grub-set-default "$(cat "$boot_once_state")"', INNER)

    def test_grub_trial_entry(self):
        helpers = "grub_entry_path() {" + INNER.split("grub_entry_path() {", 1)[1].split(
            "remove_trial_entry() {", 1)[0]
        with tempfile.TemporaryDirectory() as tmp:
            config = pathlib.Path(tmp) / "grub.cfg"
            config.write_text(GRUB_CFG)
            code = helpers.replace("/boot/grub/grub.cfg", str(config))
            result = bash(code + '\ngrub_entry_path "$1"; grub_entry_path "$2"',
                          "7.0.0-13402-generic", "7.0.0-31-generic")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.split(), [
                "gnulinux-advanced-1111>gnulinux-7.0.0-13402-generic-advanced-1111",
                "gnulinux-advanced-1111>gnulinux-7.0.0-31-generic-advanced-1111"])
            self.assertEqual(bash(code + "\ngrub_entry_path 7.0.0-3-generic").stdout, "")

            result = bash(code + '\ntrial_entry_block "$1" "$2"',
                          "gnulinux-7.0.0-13402-generic-advanced-1111", "7.0.0-13402-generic")
            self.assertEqual(result.returncode, 0, result.stderr)
            lines = result.stdout.splitlines()
            self.assertEqual(lines[0],
                             "menuentry 'BBRv3 trial boot of 7.0.0-13402-generic' --id bbrv3-trial {")
            self.assertEqual(lines[-1], "}")
            self.assertEqual(result.stdout.count("panic=10"), 1)
            self.assertIn("/boot/vmlinuz-7.0.0-13402-generic root=UUID=1111 ro console=ttyS0 panic=10",
                          result.stdout)
            self.assertNotIn("recordfail", result.stdout)
            self.assertNotIn("recovery", result.stdout)
            self.assertNotEqual(bash(code + "\ntrial_entry_block missing 7.0.0-13402-generic").returncode, 0)

    def test_boot_once_blocker(self):
        block = "boot_once_blocker=''" + INNER.split("boot_once_blocker=''", 1)[1].split(
            "# Dependency failures must stop", 1)[0]
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            tools = root / "bin"
            tools.mkdir()
            for tool in ("grub-editenv", "grub-reboot", "grub-set-default", "ip"):
                (tools / tool).write_text("#!/bin/sh\nexit 0\n")
            (tools / "grub-probe").write_text(
                '#!/bin/sh\ncase "$1" in\n  --target=fs) echo "$FAKE_FS" ;;\n'
                '  --target=abstraction) echo "$FAKE_ABSTRACTION" ;;\nesac\n')
            for tool in tools.iterdir():
                tool.chmod(0o755)
            (root / "grub.d").mkdir()
            (root / "grub").write_text("GRUB_DEFAULT=0\nGRUB_TIMEOUT=0\n")
            ours = root / "grub.d" / "99-bbrv3-installer.cfg"
            ours.write_text("GRUB_DEFAULT=saved\n")
            user_config = root / "grub.d" / "50-user.cfg"
            code = ('boot_once_requested="$1"\ngrub_default_config=' + str(ours) + "\n"
                    + block.replace("/etc/default/grub.d", str(root / "grub.d"))
                    .replace("/etc/default/grub ", str(root / "grub") + " ")
                    + '\nprintf "\\nBLOCKER=%s" "$boot_once_blocker"')

            def blocker(requested="true", fs="ext2", abstraction="", user_default=None):
                if user_default is None:
                    user_config.unlink(missing_ok=True)
                else:
                    user_config.write_text(f"GRUB_DEFAULT={user_default}\n")
                env = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}",
                           FAKE_FS=fs, FAKE_ABSTRACTION=abstraction)
                result = subprocess.run(["bash", "-c", "set -euo pipefail\n" + code, "_", requested],
                                        capture_output=True, text=True, timeout=10, env=env)
                self.assertEqual(result.returncode, 0, result.stderr)
                return result.stdout.rsplit("BLOCKER=", 1)[1]

            # The installer's own saved default does not count as a user choice.
            self.assertEqual(blocker(), "")
            self.assertIn("--no-boot-once", blocker(requested="false"))
            self.assertIn("btrfs", blocker(fs="btrfs"))
            self.assertIn("unknown", blocker(fs=""))
            self.assertIn("lvm", blocker(abstraction="lvm"))
            self.assertIn("already set to 2", blocker(user_default="2"))
            self.assertEqual(blocker(user_default="0"), "")

    def test_independent_runtime(self):
        helper = TEXT.split("<<'BBRV3_ENABLE_V1_1'\n", 1)[1].split("\nBBRV3_ENABLE_V1_1", 1)[0]
        for script in (helper, INNER):
            result = subprocess.run(['bash', '-n'], input=script, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('"$runtime_dir/enable-bbrv3.sh"', INNER)
        self.assertNotIn('install -m 0755 enable-bbrv3.sh', INNER)
        self.assertIn('sysctl -p /etc/sysctl.d/99-bbrv3.conf', helper)
        self.assertNotIn('sysctl --system', helper)

    def test_boot_files_gate(self):
        function = INNER.split('boot_files_ready() {', 1)[1].split("fallback_release=''", 1)[0]
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            (root / 'grub').mkdir()
            (root / 'grub/grub.cfg').write_text('linux /vmlinuz-test\ninitrd /initrd.img-test\n')
            (root / 'vmlinuz-test').write_text('image')
            code = ('boot_files_ready() {' + function).replace('/boot/', tmp + '/')
            self.assertNotEqual(bash(code + '\nboot_files_ready test').returncode, 0)
            (root / 'initrd.img-test').write_text('initramfs')
            self.assertEqual(bash(code + '\nboot_files_ready test').returncode, 0)
            (root / 'grub/grub.cfg').write_text('linux /vmlinuz-test\n')
            self.assertNotEqual(bash(code + '\nboot_files_ready test').returncode, 0)

    def test_space_budget_same_device(self):
        code = INNER.split("<<'SPACE_CHECK'\n", 1)[1].split('\nSPACE_CHECK', 1)[0]
        # Each check separately would fit; their summed requirement must fail.
        with mock.patch('sys.argv', ['check', 'kernel.deb']), \
             mock.patch('subprocess.check_output', return_value='1024'), \
             mock.patch('os.stat', return_value=types.SimpleNamespace(st_dev=1)), \
             mock.patch('shutil.disk_usage', return_value=types.SimpleNamespace(free=800 * 1024**2)):
            with self.assertRaises(SystemExit):
                exec(compile(code, '<space-check>', 'exec'), {})
        with mock.patch('sys.argv', ['check', 'kernel.deb']), \
             mock.patch('subprocess.check_output', return_value='1024'), \
             mock.patch('os.stat', return_value=types.SimpleNamespace(st_dev=1)), \
             mock.patch('shutil.disk_usage', return_value=types.SimpleNamespace(free=2 * 1024**3)):
            exec(compile(code, '<space-check>', 'exec'), {})


if __name__ == "__main__":
    unittest.main()
