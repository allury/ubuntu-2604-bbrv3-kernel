"""Experimental IPv4 sender test. Default is plan-only; execute in a disposable VM."""
import argparse
import hashlib
import json
import os
import pathlib
import platform
import shutil
import subprocess
import time
import uuid


def cases():
    return [
        dict(name="rtt20-clean", rtt_ms=20, loss_pct=0, rate_mbit=100),
        dict(name="rtt100-clean", rtt_ms=100, loss_pct=0, rate_mbit=100),
        dict(name="rtt100-loss1", rtt_ms=100, loss_pct=1, rate_mbit=100),
    ]


def command(*args, timeout=30):
    return subprocess.run(list(args), check=True, text=True, capture_output=True,
                          timeout=timeout).stdout


def validate_iperf(data):
    if data.get("error"):
        raise RuntimeError(data["error"])
    if data["start"]["test_start"]["protocol"] != "TCP":
        raise RuntimeError("Not TCP")
    if data["end"].get("sender_tcp_congestion") != "bbr":
        raise RuntimeError("Sender did not report bbr")
    received = data["end"]["sum_received"]
    if received["bytes"] <= 0 or received["bits_per_second"] <= 0:
        raise RuntimeError("No received traffic")
    return dict(bits_per_second=received["bits_per_second"],
                bytes=received["bytes"],
                retransmits=data["end"]["sum_sent"].get("retransmits"))


def execute(args):
    if platform.system() != "Linux" or os.geteuid() != 0:
        raise SystemExit("Requires root in a disposable Linux VM")
    for tool in ("ip", "tc", "iperf3", "ping", "ss", "sysctl", "ethtool",
                 "modprobe", "systemd-detect-virt", "dmesg"):
        if not shutil.which(tool):
            raise SystemExit("Missing: " + tool)
    command("systemd-detect-virt", "--vm")
    if platform.release() != args.expected_kernel:
        raise SystemExit("Wrong running kernel")
    command("modprobe", "tcp_bbr")
    if pathlib.Path("/sys/module/tcp_bbr/version").read_text().strip() != "3":
        raise SystemExit("Requires BBR module version 3")
    # Never overwrite a previous test result.
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    metadata = dict(kernel=platform.release(), bbr_version="3",
                    duration=args.duration, repeats=args.repeats, cases=cases(),
                    iperf=command("iperf3", "--version"), tc=command("tc", "-V"),
                    script_sha256=hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),
                    production_ready=False)
    (output / "environment.json").write_text(json.dumps(metadata, indent=2))
    (output / "dmesg-before.txt").write_text(command("dmesg"))
    prefix = "b3-" + uuid.uuid4().hex[:8]
    sender, router, receiver = [prefix + suffix for suffix in ("s", "r", "d")]
    created = []
    children = []
    results = []

    def ns(name, *argv, timeout=30):
        return command("ip", "netns", "exec", name, *argv, timeout=timeout)

    try:
        for name in (sender, router, receiver):
            command("ip", "netns", "add", name)
            created.append(name)
            ns(name, "ip", "link", "set", "lo", "up")
        # Create both veth ends inside owned namespaces, never on host interfaces.
        ns(sender, "ip", "link", "add", "s0", "type", "veth", "peer", "name", "r0")
        ns(sender, "ip", "link", "set", "r0", "netns", router)
        ns(router, "ip", "link", "add", "r1", "type", "veth", "peer", "name", "d0")
        ns(router, "ip", "link", "set", "d0", "netns", receiver)
        for name, dev, addr in (
            (sender, "s0", "192.0.2.1/30"), (router, "r0", "192.0.2.2/30"),
            (router, "r1", "198.51.100.1/30"), (receiver, "d0", "198.51.100.2/30"),
        ):
            ns(name, "ip", "addr", "add", addr, "dev", dev)
            ns(name, "ip", "link", "set", dev, "mtu", "1500", "up")
            ns(name, "ethtool", "-K", dev, "tso", "off", "gso", "off", "gro", "off")
        ns(sender, "ip", "route", "add", "default", "via", "192.0.2.2")
        ns(receiver, "ip", "route", "add", "default", "via", "198.51.100.1")
        ns(router, "sysctl", "-w", "net.ipv4.ip_forward=1")
        for name in (sender, receiver):
            ns(name, "sysctl", "-w", "net.ipv4.tcp_ecn=0")
        ns(sender, "tc", "qdisc", "add", "dev", "s0", "root", "fq")
        for case in cases():
            # Delay on both router egresses yields the requested round-trip delay.
            # Loss is forward-path only; rate caps both data and ACK directions.
            for dev, loss in (("r1", case["loss_pct"]), ("r0", 0)):
                ns(router, "tc", "qdisc", "replace", "dev", dev, "root", "netem",
                   "limit", "1000", "delay", str(case["rtt_ms"] / 2) + "ms",
                   "loss", str(loss) + "%", "rate", str(case["rate_mbit"]) + "mbit")
            for repeat in range(args.repeats):
                stem = case["name"] + "-" + str(repeat)
                (output / (stem + "-ping.txt")).write_text(
                    ns(sender, "ping", "-n", "-c", "5", "-W", "3", "198.51.100.2"))
                server_log = open(output / (stem + "-server.txt"), "w")
                server = subprocess.Popen(
                    ["ip", "netns", "exec", receiver, "iperf3", "-s", "-1"],
                    stdout=server_log, stderr=subprocess.STDOUT)
                children.append(server)
                try:
                    ready = False
                    for _ in range(50):
                        if server.poll() is not None:
                            raise RuntimeError("iperf server exited before listening")
                        if ":5201" in ns(receiver, "ss", "-ltn"):
                            ready = True
                            break
                        time.sleep(0.1)
                    if not ready:
                        raise RuntimeError("iperf server readiness timeout")
                    raw = ns(sender, "iperf3", "-c", "198.51.100.2", "-C", "bbr",
                             "-t", str(args.duration), "-J", "--get-server-output",
                             timeout=args.duration + 60)
                    (output / (stem + ".json")).write_text(raw)
                    summary = validate_iperf(json.loads(raw))
                    server.wait(timeout=15)
                    if server.returncode:
                        raise RuntimeError("iperf server failed")
                    results.append(dict(case=case["name"], repeat=repeat, **summary))
                finally:
                    if server.poll() is None:
                        server.terminate()
                        try:
                            server.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            server.kill()
                            server.wait(timeout=5)
                    server_log.close()
                stats = ns(router, "tc", "-s", "qdisc", "show")
                (output / (stem + "-tc.txt")).write_text(stats)
        (output / "results.json").write_text(json.dumps(results, indent=2))
        print("MATRIX_COMPLETED: measurements only; no automatic stability verdict")
    finally:
        # Only namespaces actually created by this invocation are removed.
        cleanup_errors = []
        for child in children:
            if child.poll() is None:
                child.kill()
                child.wait(timeout=5)
        for name in reversed(created):
            try:
                command("ip", "netns", "del", name)
            except (subprocess.SubprocessError, OSError) as error:
                cleanup_errors.append(str(error))
        (output / "cleanup-errors.json").write_text(json.dumps(cleanup_errors))
        (output / "dmesg-after.txt").write_text(command("dmesg"))
        if cleanup_errors:
            raise RuntimeError("Namespace cleanup incomplete; inspect cleanup-errors.json")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--expected-kernel")
    parser.add_argument("--output", type=pathlib.Path)
    parser.add_argument("--duration", type=int, default=30)
    parser.add_argument("--repeats", type=int, default=5)
    args = parser.parse_args()
    if not 10 <= args.duration <= 3600 or not 1 <= args.repeats <= 20:
        parser.error("duration must be 10..3600 seconds; repeats 1..20")
    if not args.execute:
        print(json.dumps(dict(cases=cases(), duration=args.duration,
                              repeats=args.repeats, execute=False), indent=2))
        return
    if not args.expected_kernel or not args.output:
        parser.error("--execute requires --expected-kernel and --output")
    execute(args)


if __name__ == "__main__":
    main()
