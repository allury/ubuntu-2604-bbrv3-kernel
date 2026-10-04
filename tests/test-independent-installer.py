"""Exercise the actual embedded shell branches without installing or rebooting."""
import os
import pathlib
import shutil
import subprocess
import tempfile
import types
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
TEXT = (ROOT / "installer/install.sh").read_text()
INNER = TEXT.split("<<'BBRV3_INSTALLER_V1'\n", 1)[1].split("\nBBRV3_INSTALLER_V1", 1)[0]
# The embedded logic's variables and helper functions, without its root check.
HELPERS = INNER.split('if [[ "$mode" == test ]]; then', 1)[0].replace(
    "[[ $EUID == 0 ]] || die 'Run with sudo.'\n", "")


def bash(code, *args):
    return subprocess.run(["bash", "-c", "set -euo pipefail\n" + code, "_", *args],
                          capture_output=True, text=True, timeout=10,
                          stdin=subprocess.DEVNULL)


def helpers(root):
    """The helpers with /boot moved under root."""
    return HELPERS.replace("/boot/", f"{root}/boot/")


def fake_dpkg(*lines):
    return "dpkg-query() { cat <<'DPKG'\n" + "\n".join(lines) + "\nDPKG\n}\n"


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
        result = bash("die() { exit 19; }; action=install; requested_tag=latest" + parser +
                      '\nprintf "%s " "$requested_tag" "${install_options[@]}"',
                      "--tag", "ubuntu-26.04-bbrv3-7.0.0-30.30-p2",
                      "--allow-no-fallback", "--reboot", "--no-boot-once")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout,
                         "ubuntu-26.04-bbrv3-7.0.0-30.30-p2 --allow-no-fallback --reboot --no-boot-once ")

    def test_outer_actions(self):
        parser = "action=install" + TEXT.split("action=install", 1)[1].split(
            'if [[ "$action" != install ]]; then', 1)[0]
        code = ("die() { exit 19; }\n" + parser +
                '\nprintf "%s|%s|%s|%s" "$action" "$requested_tag" "${install_options[*]}" "${manage_options[*]}"')
        for args, expected in [
            # Without a terminal, no arguments still install, as in earlier versions.
            ([], "install|latest||"),
            (["--reboot"], "install|latest|--reboot|"),
            (["install", "--allow-no-fallback"], "install|latest|--allow-no-fallback|"),
            (["status"], "status|latest||"),
            (["clean", "--yes"], "clean|latest||--yes"),
            (["fallback", "--yes"], "fallback|latest||--yes"),
            (["restore", "--yes", "--reboot"], "restore|latest||--yes --reboot"),
        ]:
            result = bash(code, *args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, expected)
        for args in (["status", "--yes"], ["clean", "--tag", "x"], ["fallback", "--reboot"],
                     ["install", "--yes"], ["bogus"], ["restore", "--no-boot-once"]):
            self.assertEqual(bash(code, *args).returncode, 19, args)

    def test_secure_boot_check(self):
        block = "if [[ -d /sys/firmware/efi ]]; then" + INNER.split(
            "if [[ -d /sys/firmware/efi ]]; then", 1)[1].split("\nfor file in SHA256SUMS", 1)[0]
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            tools = root / "bin"
            tools.mkdir()
            for name in ("grep", "ls", "od", "tr"):
                (tools / name).symlink_to(shutil.which(name))
            efi = root / "efi"
            code = ("set -euo pipefail\ndie() { printf '%s' \"$*\" >&2; exit 19; }\n" +
                    block.replace("/sys/firmware/efi", str(efi)) + "\necho passed")

            def check(mokutil=None, variable=None, other_variable=False, uefi=True):
                shutil.rmtree(efi, ignore_errors=True)
                (tools / "mokutil").unlink(missing_ok=True)
                if uefi:
                    (efi / "efivars").mkdir(parents=True)
                    if other_variable:
                        (efi / "efivars/BootOrder-8be4df61-93ca-11d2-aa0d-00e098032b8c").write_bytes(b"\x07\0\0\0\0\0")
                    if variable is not None:
                        (efi / "efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c").write_bytes(
                            b"\x06\0\0\0" + bytes([variable]))
                if mokutil is not None:
                    text, status = mokutil
                    (tools / "mokutil").write_text(f"#!/bin/sh\nprintf '%s\\n' \"{text}\"\nexit {status}\n")
                    (tools / "mokutil").chmod(0o755)
                result = subprocess.run(["/bin/bash", "-c", code], capture_output=True, text=True, timeout=10,
                                        env={"PATH": str(tools)})
                return result.returncode, result.stdout + result.stderr

            self.assertEqual(check(mokutil=("SecureBoot disabled", 0)), (0, "passed\n"))
            self.assertEqual(check(mokutil=("SecureBoot enabled", 0))[0], 19)
            # Firmware without Secure Boot boots unsigned kernels.
            self.assertEqual(check(mokutil=("This system doesn't support Secure Boot", 255)), (0, "passed\n"))
            status, output = check(mokutil=("EFI variables are not supported on this system", 255))
            self.assertEqual(status, 19)
            self.assertIn("Cannot determine Secure Boot state", output)
            # Without mokutil the firmware variable decides.
            self.assertEqual(check(variable=0), (0, "passed\n"))
            status, output = check(variable=1)
            self.assertEqual(status, 19)
            self.assertIn("Unsigned release requires Secure Boot disabled", output)
            self.assertEqual(check(other_variable=True), (0, "passed\n"))
            self.assertEqual(check()[0], 19)
            self.assertEqual(check(uefi=False), (0, "passed\n"))

    def test_github_token_is_optional(self):
        function = "github_api() {" + TEXT.split("github_api() {", 1)[1].split("\n}\n", 1)[0] + "\n}\n"
        code = "set -euo pipefail\ncurl() { printf '%s\\n' \"$@\"; }\n" + function + "github_api https://api.github.com/x"
        without = {key: value for key, value in os.environ.items() if key != "GITHUB_TOKEN"}
        anonymous = subprocess.run(["bash", "-c", code], capture_output=True, text=True, timeout=10, env=without)
        self.assertEqual(anonymous.returncode, 0, anonymous.stderr)
        self.assertIn("https://api.github.com/x", anonymous.stdout.splitlines())
        self.assertNotIn("Authorization", anonymous.stdout)
        with_token = subprocess.run(["bash", "-c", code], capture_output=True, text=True, timeout=10,
                                    env=dict(without, GITHUB_TOKEN="secret"))
        self.assertEqual(with_token.returncode, 0, with_token.stderr)
        self.assertIn("Authorization: Bearer secret", with_token.stdout.splitlines())
        # Only the API requests carry the token, never the asset downloads.
        self.assertEqual(TEXT.count("github_api \""), 2)

    def test_help_needs_no_root(self):
        result = subprocess.run(["bash", str(ROOT / "installer/install.sh"), "--help"],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("用法", result.stdout)
        self.assertIn("restore", result.stdout)

    def test_actions_extract_the_embedded_runtime(self):
        loop = "for part in BBRV3_ENABLE_V1_1" + TEXT.split("for part in BBRV3_ENABLE_V1_1", 1)[1].split(
            "\n  done\n", 1)[0] + "\n  done\n"
        with tempfile.TemporaryDirectory() as tmp:
            result = bash(f'die() {{ exit 19; }}\nself="{ROOT / "installer/install.sh"}"\n'
                          f'runtime_dir="{tmp}"\n' + loop)
            self.assertEqual(result.returncode, 0, result.stderr)
            for name, filename in (("BBRV3_ENABLE_V1_1", "enable-bbrv3.sh"),
                                   ("BBRV3_CONFIG_V1_1", "bbrv3.sysctl.conf"),
                                   ("BBRV3_INSTALLER_V1", "install-bbrv3.sh")):
                embedded = TEXT.split(f"<<'{name}'\n", 1)[1].split(f"\n{name}\n", 1)[0] + "\n"
                self.assertEqual((pathlib.Path(tmp) / filename).read_text(), embedded, name)

    def test_manage_options(self):
        parser = "assume_yes=false" + INNER.split("assume_yes=false", 1)[1].split(
            'if [[ "$mode" == find-fallback ]]', 1)[0]
        code = ('die() { exit 19; }\nmode="$1"\n' + parser +
                '\nprintf "%s %s %s" "$assume_yes" "$reboot_after" "$summary_only"')
        for args, expected in [
            (["status"], "false false false"), (["status", "--summary"], "false false true"),
            (["clean", "--yes"], "true false false"), (["add-fallback", "--yes"], "true false false"),
            (["restore", "--yes", "--reboot"], "true true false"), (["find-fallback"], "false false false"),
        ]:
            result = bash(code, *args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, expected)
        for args in (["status", "--yes"], ["clean", "--reboot"], ["find-fallback", "--yes"],
                     ["restore", "--summary"]):
            self.assertEqual(bash(code, *args).returncode, 19, args)

    def test_confirm_needs_a_terminal_or_yes(self):
        function = "confirm() {" + INNER.split("confirm() {", 1)[1].split("\n}\n", 1)[0] + "\n}\n"
        code = "die() { printf '%s' \"$*\" >&2; exit 19; }\n" + function
        result = bash(code + "assume_yes=false\nconfirm 'Go?'\necho reached")
        self.assertEqual(result.returncode, 19)
        self.assertIn("--yes", result.stderr)
        self.assertEqual(bash(code + "assume_yes=true\nconfirm 'Go?'\necho reached").stdout, "reached\n")

    def test_kernel_records_and_fallback(self):
        with tempfile.TemporaryDirectory() as tmp:
            boot = pathlib.Path(tmp) / "boot"
            (boot / "grub").mkdir(parents=True)
            references = []
            for release in ("7.0.0-31-generic", "7.0.0-38-generic", "7.0.0-13402-generic"):
                (boot / f"vmlinuz-{release}").write_text("image")
                (boot / f"initrd.img-{release}").write_text("initramfs")
                references.append(f"linux /boot/vmlinuz-{release}\ninitrd /boot/initrd.img-{release}\n")
            (boot / "grub/grub.cfg").write_text("".join(references))
            code = helpers(tmp) + fake_dpkg(
                "ii \tlinux-image-7.0.0-31-generic\t7.0.0-31.31\tlinux-signed",
                "hi \tlinux-image-7.0.0-38-generic\t7.0.0-38.38\tlinux-signed",
                "rc \tlinux-image-7.0.0-14-generic\t7.0.0-14.14\tlinux-signed",
                "ii \tlinux-image-unsigned-7.0.0-13402-generic\t7.0.0-13402.34+bbrv3.2\tlinux",
                "hi \tlinux-image-unsigned-7.0.0-13102-generic\t7.0.0-13102.31+bbrv3.2\tlinux",
                "ii \tlinux-image-6.12.0-x64v3-generic\t6.12.0-1\txanmod")
            result = bash(code + "kernel_records")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.splitlines(), [
                "7.0.0-31-generic\tofficial\t-",
                "7.0.0-38-generic\tofficial\theld",
                "7.0.0-13402-generic\tbbrv3\t-",
                "7.0.0-13102-generic\tbbrv3\theld",
                "6.12.0-x64v3-generic\tother\t-"])
            # A held official kernel counts as a fallback, and the newest one wins.
            self.assertEqual(bash(code + "find_fallback_release 7.0.0-13402-generic").stdout,
                             "7.0.0-38-generic\n")
            self.assertEqual(bash(code + "find_fallback_release 7.0.0-38-generic").stdout,
                             "7.0.0-31-generic\n")
            (boot / "initrd.img-7.0.0-31-generic").unlink()
            self.assertNotEqual(bash(code + "find_fallback_release 7.0.0-38-generic").returncode, 0)

    def test_clean_plan(self):
        def plan(running, default, *kernels):
            lines = "".join(f"{release}\t{kind}\t{ready}\n" for release, kind, ready in kernels)
            result = subprocess.run(["bash", "-c", "set -euo pipefail\n" + HELPERS + 'clean_plan "$1" "$2"',
                                     "_", running, default],
                                    input=lines, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout.splitlines()

        new, old, older = "7.0.0-13402-generic", "7.0.0-13102-generic", "7.0.0-13002-generic"
        official = "7.0.0-38-generic"
        # Without an official kernel the newest old BBRv3 kernel stays as the fallback.
        self.assertEqual(plan(new, new, (new, "bbrv3", "yes"), (old, "bbrv3", "yes")),
                         [f"keep\t{new}\trunning", f"keep\t{old}\tfallback"])
        self.assertEqual(plan(new, new, (new, "bbrv3", "yes"), (old, "bbrv3", "yes"),
                              (official, "official", "yes")),
                         [f"keep\t{new}\trunning", f"remove\t{old}"])
        self.assertEqual(plan(new, new, (older, "bbrv3", "yes"), (new, "bbrv3", "yes"), (old, "bbrv3", "yes")),
                         [f"keep\t{new}\trunning", f"keep\t{old}\tfallback", f"remove\t{older}"])
        # A kernel whose boot files are incomplete is no fallback and may go.
        self.assertEqual(plan(new, new, (new, "bbrv3", "yes"), (old, "bbrv3", "no"), (older, "bbrv3", "yes")),
                         [f"keep\t{new}\trunning", f"remove\t{old}", f"keep\t{older}\tfallback"])
        self.assertEqual(plan(new, new, (new, "bbrv3", "yes"), (old, "bbrv3", "yes"),
                              (official, "official", "no")),
                         [f"keep\t{new}\trunning", f"keep\t{old}\tfallback"])
        # The default kernel stays, even while another kernel runs.
        self.assertEqual(plan(official, new, (new, "bbrv3", "yes"), (official, "official", "yes")),
                         [f"keep\t{new}\tdefault"])

    def test_bbrv3_packages(self):
        result = bash(HELPERS + fake_dpkg(
            "ii \tlinux-image-unsigned-7.0.0-13102-generic\t7.0.0-13102.31+bbrv3.2",
            "hi \tlinux-main-modules-zfs-7.0.0-13102-generic\t7.0.0-13102.31+bbrv3.2",
            "ii \tlinux-headers-7.0.0-13102\t7.0.0-13102.31+bbrv3.2",
            "rc \tlinux-buildinfo-7.0.0-13102-generic\t7.0.0-13102.31+bbrv3.2",
            "ii \tlinux-lib-rust-7.0.0-13102-generic:amd64\t7.0.0-13102.31+bbrv3.2",
            "un \tlinux-tools-7.0.0-13102-generic\t",
            "ii \tlinux-image-unsigned-7.0.0-13402-generic\t7.0.0-13402.34+bbrv3.2",
            "ii \tlinux-headers-7.0.0-131020\t7.0.0-131020.1+bbrv3.1",
            "ii \tlinux-modules-7.0.0-13102-generic\t7.0.0-13102.31") +
            "bbrv3_packages 7.0.0-13102-generic")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            "linux-image-unsigned-7.0.0-13102-generic",
            "linux-main-modules-zfs-7.0.0-13102-generic",
            "linux-headers-7.0.0-13102",
            "linux-buildinfo-7.0.0-13102-generic",
            "linux-lib-rust-7.0.0-13102-generic"])

    def test_default_boot_release(self):
        with tempfile.TemporaryDirectory() as tmp:
            (pathlib.Path(tmp) / "boot/grub").mkdir(parents=True)
            (pathlib.Path(tmp) / "boot/grub/grub.cfg").write_text(GRUB_CFG)
            code = ("set -euo pipefail\n" + helpers(tmp) +
                    'grub_default_value() { printf %s "$DEFAULT"; }\n'
                    'grub-editenv() { printf "saved_entry=%s\\n" "$SAVED"; }\n'
                    "default_boot_release")

            def boot_default(value, saved=""):
                result = subprocess.run(["bash", "-c", code], capture_output=True, text=True, timeout=10,
                                        env=dict(os.environ, DEFAULT=value, SAVED=saved))
                self.assertEqual(result.returncode, 0, result.stderr)
                return result.stdout.strip()

            self.assertEqual(boot_default("saved", "gnulinux-advanced-1111>gnulinux-7.0.0-31-generic-advanced-1111"),
                             "7.0.0-31-generic")
            self.assertEqual(boot_default("saved", "gnulinux-7.0.0-13402-generic-advanced-1111"),
                             "7.0.0-13402-generic")
            # Titles and numbers cannot be resolved safely.
            self.assertEqual(boot_default("saved", "Advanced options for Ubuntu>Ubuntu, with Linux 7.0.0-31-generic"), "")
            self.assertEqual(boot_default("2"), "")
            # Without a saved entry GRUB boots the first one.
            self.assertEqual(boot_default("saved"), "7.0.0-13402-generic")
            self.assertEqual(boot_default("0"), "7.0.0-13402-generic")

    def test_pfifo_fast_queues_move_to_fq(self):
        helper = TEXT.split("<<'BBRV3_ENABLE_V1_1'\n", 1)[1].split("\nBBRV3_ENABLE_V1_1", 1)[0]
        moves = "command -v tc" + helper.split("command -v tc", 1)[1]
        with tempfile.TemporaryDirectory() as tmp:
            calls = pathlib.Path(tmp) / "calls"
            fake_tc = pathlib.Path(tmp) / "tc"
            fake_tc.write_text(
                "#!/bin/sh\n"
                "if [ \"$2\" = show ]; then cat <<'TC'\n"
                "qdisc noqueue 0: dev lo root refcnt 2\n"
                "qdisc pfifo_fast 0: dev ens7 root refcnt 2 bands 3 priomap 1 2 2 2\n"
                "qdisc mq 0: dev eth1 root\n"
                "qdisc pfifo_fast 0: dev eth1 parent :2 bands 3 priomap 1 2 2 2\n"
                "qdisc fq 0: dev eth1 parent :1 limit 10000p\n"
                "qdisc fq_codel 0: dev eth2 root refcnt 2 limit 10240p\n"
                "qdisc cake 8001: dev wan0 root refcnt 2 bandwidth 100Mbit\n"
                "TC\n"
                f"else echo \"$*\" >> {calls}; [ \"$4\" != eth1 ]; fi\n")
            fake_tc.chmod(0o755)
            result = subprocess.run(["bash", "-c", "set -euo pipefail\n" + moves],
                                    capture_output=True, text=True, timeout=10,
                                    env=dict(os.environ, PATH=f"{tmp}:{os.environ['PATH']}"))
            self.assertEqual(result.returncode, 0, result.stderr)
            # Only the kernel's built-in pfifo_fast moves; fq_codel, cake and fq stay.
            self.assertEqual(calls.read_text().splitlines(), [
                "qdisc replace dev ens7 root fq", "qdisc replace dev eth1 parent :2 fq"])
            self.assertIn("PASS: the root queue of ens7 moved from pfifo_fast to fq.", result.stdout)
            # A failed move is reported and never fails the verification.
            self.assertIn("NOTE: the parent :2 queue of eth1 stays pfifo_fast.", result.stdout)

    def test_status_queue_summary(self):
        program = INNER.split("queues=\"$(tc qdisc show 2>/dev/null | awk '", 1)[1].split("' || true)\"", 1)[0]
        result = subprocess.run(["awk", program], input=(
            "qdisc noqueue 0: dev lo root refcnt 2\n"
            "qdisc pfifo_fast 0: dev ens7 root refcnt 2 bands 3\n"
            "qdisc mq 0: dev eth1 root\n"
            "qdisc pfifo_fast 0: dev eth1 parent :2 bands 3\n"
            "qdisc fq 0: dev eth1 parent :1 limit 10000p\n"
            "qdisc fq 0: dev eth1 parent :3 limit 10000p\n"
            "qdisc noqueue 0: dev docker0 root refcnt 2\n"), capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["  ens7：pfifo_fast", "  eth1：mq（子队列：pfifo_fast fq）"])

    def test_dracut_file_matches_the_manual_fix(self):
        # Machines fixed by hand already have exactly this file; installing
        # must leave one identical file, and restoring removes only that.
        self.assertIn("dracut_config=/etc/dracut.conf.d/90-bbrv3.conf\n", INNER)
        self.assertIn("dracut_line='force_drivers+=\" sch_fq tcp_bbr \"'\n", INNER)
        self.assertIn('if [[ "$dracut_ours" == true ]]; then rm -f -- "$dracut_config"; fi', INNER)

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
        function = INNER.split('boot_files_ready() {', 1)[1].split("\n}\n", 1)[0] + "\n}\n"
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
