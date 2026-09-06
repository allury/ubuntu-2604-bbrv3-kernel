"""Apply experimental patches to a temporary Git index, never to the checkout."""
import argparse
import hashlib
import json
import os
import pathlib
import subprocess
import tempfile

BASE = "d974a4063f5c03c13b4f241a9ab511750e0b9f12"
HERE = pathlib.Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ubuntu", required=True, type=pathlib.Path)
    args = parser.parse_args()
    repo = args.ubuntu.resolve()
    with tempfile.TemporaryDirectory(prefix="bbr-port-index-") as temporary:
        env = dict(os.environ, GIT_INDEX_FILE=str(pathlib.Path(temporary) / "index"),
                   GIT_NO_LAZY_FETCH="1", GIT_TERMINAL_PROMPT="0")

        def git(*argv):
            return subprocess.run(
                ["git", "-c", "safe.directory=" + str(repo), "-C", str(repo), *argv],
                env=env, capture_output=True, check=True).stdout

        git("cat-file", "-e", BASE + "^{commit}")
        git("read-tree", BASE)
        checks = []
        for name in (HERE / "patches/series").read_text().splitlines():
            if not name or name.startswith("#"):
                continue
            if pathlib.Path(name).name != name or not name.endswith(".patch"):
                raise SystemExit("Unsafe series entry")
            patch = HERE / "patches" / name
            content = patch.read_bytes()
            if b"\r" in content:
                raise SystemExit("CRLF patch rejected")
            git("apply", "--cached", "--check", "--whitespace=error", str(patch))
            git("apply", "--cached", "--whitespace=error", str(patch))
            checks.append(dict(patch=name, sha256=hashlib.sha256(content).hexdigest()))
        if not checks:
            raise SystemExit("Empty patch series")
        ack = git("show", ":net/ipv4/tcp_input.c").decode()
        timer = git("show", ":net/ipv4/tcp_timer.c").decode()
        if 'rs.prior_in_flight = tcp_packets_in_flight(tp);\n\ttcp_rate_check_app_limited(sk);' not in ack:
            raise SystemExit("ACK call ordering check failed")
        if '\ttcp_rate_check_app_limited(sk);\n\ttcp_mstamp_refresh(tcp_sk(sk));\n\tevent = icsk->icsk_pending;' not in timer:
            raise SystemExit("Timer call ordering check failed")
        header = git("show", ":include/net/tcp.h").decode()
        sock_header = git("show", ":include/linux/tcp.h").decode()
        for field in ("first_tx_mstamp", "delivered_mstamp"):
            if "u32 " + field + ";" not in header:
                raise SystemExit("skb timestamp width check failed")
            if "u64\t" + field + ";" not in sock_header:
                raise SystemExit("tcp_sock timestamp unexpectedly narrowed")
        if ack.count("tcp_stamp32_us_delta(") != 2:
            raise SystemExit("Expected two relocated rate sampling call sites")
        print(json.dumps(dict(base=BASE, patches=checks, source_order_checks="passed",
                              complete_bbrv3_port=False, compiled=False), indent=2))
        print(git("diff", "--cached", "--stat", BASE).decode())


if __name__ == "__main__":
    main()
