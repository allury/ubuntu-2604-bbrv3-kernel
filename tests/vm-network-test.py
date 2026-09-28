#!/usr/bin/env python3
"""Measure bulk TCP transfers through an emulated bottleneck.

Runs as root inside the VM acceptance guest. Three network namespaces form a
sender -> router -> receiver path. The router's netem limits the data
direction to a fixed rate with a bounded buffer and optional random loss, and
delays the ACK direction by the round-trip time. Every profile runs once per
congestion control, and each run prints one VM_NETWORK_RESULT line of
key=value pairs. It uses only the Python standard library, ip and tc.

This is a controlled laboratory comparison inside one VM, not a measurement
of real Internet paths.
"""
import argparse
import json
import math
import os
import shutil
import socket
import struct
import subprocess
import sys
import time

TCP_CC_INFO = 26
PORT = 5201
SENDER_ADDRESS = "10.201.1.1"
RECEIVER_ADDRESS = "10.201.2.1"
NAMESPACES = ("bbrv3-snd", "bbrv3-rtr", "bbrv3-rcv")
CONGESTION_CONTROLS = ("cubic", "bbr")
# name, bottleneck rate (Mbit/s), round-trip time (ms), random loss (%),
# bottleneck buffer (bandwidth-delay products), duration (s)
PROFILES = (
    ("rtt40", 100, 40, 0.0, 1.0, 20),
    ("rtt40-shallow", 100, 40, 0.0, 0.2, 20),
    ("rtt100-loss1", 100, 100, 1.0, 1.0, 20),
    ("rtt150-loss0.1-long", 50, 150, 0.1, 1.0, 60),
)


def run(*args, check=True):
    return subprocess.run(args, check=check, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)


def in_ns(namespace, *args, check=True):
    return run("ip", "netns", "exec", namespace, *args, check=check)


def teardown():
    for namespace in NAMESPACES:
        run("ip", "netns", "delete", namespace, check=False)


def setup():
    """Build the path and report whether segmentation offloads were turned off."""
    teardown()
    for namespace in NAMESPACES:
        run("ip", "netns", "add", namespace)
    run("ip", "link", "add", "snd-r", "netns", "bbrv3-snd", "type", "veth",
        "peer", "name", "r-snd", "netns", "bbrv3-rtr")
    run("ip", "link", "add", "rcv-r", "netns", "bbrv3-rcv", "type", "veth",
        "peer", "name", "r-rcv", "netns", "bbrv3-rtr")
    links = (("bbrv3-snd", "snd-r", SENDER_ADDRESS + "/24"),
             ("bbrv3-rtr", "r-snd", "10.201.1.254/24"),
             ("bbrv3-rtr", "r-rcv", "10.201.2.254/24"),
             ("bbrv3-rcv", "rcv-r", RECEIVER_ADDRESS + "/24"))
    # Without offloads the bottleneck queue limit counts real packets, not
    # 64 KiB segmentation bursts.
    offloads = "off" if shutil.which("ethtool") else "on"
    for namespace, device, address in links:
        in_ns(namespace, "ip", "addr", "add", address, "dev", device)
        in_ns(namespace, "ip", "link", "set", device, "up")
        if offloads == "off":
            result = in_ns(namespace, "ethtool", "-K", device, "tso", "off", "gso", "off", "gro", "off",
                           check=False)
            if result.returncode != 0:
                offloads = "partly-on"
    for namespace in NAMESPACES:
        in_ns(namespace, "ip", "link", "set", "lo", "up")
    in_ns("bbrv3-snd", "ip", "route", "add", "default", "via", "10.201.1.254")
    in_ns("bbrv3-rcv", "ip", "route", "add", "default", "via", "10.201.2.254")
    in_ns("bbrv3-rtr", "sysctl", "-qw", "net.ipv4.ip_forward=1")
    # Pace the sender the same way on every kernel.
    in_ns("bbrv3-snd", "tc", "qdisc", "replace", "dev", "snd-r", "root", "fq")
    return offloads


def shape(rate_mbit, rtt_ms, loss_pct, buffer_bdp):
    bdp_bytes = rate_mbit * 1e6 / 8 * rtt_ms / 1000
    limit = max(16, math.ceil(bdp_bytes * buffer_bdp / 1514))
    data = ["tc", "qdisc", "replace", "dev", "r-rcv", "root", "netem",
            "rate", f"{rate_mbit}mbit", "limit", str(limit)]
    if loss_pct:
        data += ["loss", f"{loss_pct}%"]
    in_ns("bbrv3-rtr", *data)
    in_ns("bbrv3-rtr", "tc", "qdisc", "replace", "dev", "r-snd", "root", "netem",
          "delay", f"{rtt_ms}ms", "limit", "100000")


def tcp_info(sock):
    raw = sock.getsockopt(socket.IPPROTO_TCP, socket.TCP_INFO, 256)

    def field(fmt, offset):
        size = struct.calcsize(fmt)
        return struct.unpack_from(fmt, raw, offset)[0] if len(raw) >= offset + size else 0

    return {
        "rtt_us": field("<I", 68),
        "bytes_acked": field("<Q", 120),
        "min_rtt_us": field("<I", 148),
        "bytes_sent": field("<Q", 200),
        "bytes_retrans": field("<Q", 208),
    }


def bbr_info(sock):
    raw = sock.getsockopt(socket.IPPROTO_TCP, TCP_CC_INFO, 64)
    if len(raw) < 20:
        return {}
    bw_lo, bw_hi = struct.unpack_from("<II", raw, 0)
    # The BBRv3 patch extends struct tcp_bbr_info to 52 bytes, with the
    # algorithm version at offset 39; the original layout has 20 bytes.
    version = raw[39] if len(raw) >= 52 else 1
    return {"bbr_bw_mbit": ((bw_hi << 32) | bw_lo) * 8 / 1e6, "bbr_version": version}


def send(congestion_control, seconds):
    with socket.socket() as sock:
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_CONGESTION, congestion_control.encode())
        sock.settimeout(1)
        sock.connect((RECEIVER_ADDRESS, PORT))
        payload = bytes(262144)
        start = time.monotonic()
        halfway = None
        while (now := time.monotonic()) < start + seconds:
            if halfway is None and now >= start + seconds / 2:
                halfway = (now, tcp_info(sock)["bytes_acked"])
            try:
                sock.send(payload)
            except socket.timeout:
                pass
        finish = time.monotonic()
        info = tcp_info(sock)
        extra = bbr_info(sock) if congestion_control == "bbr" else {}
        selected = sock.getsockopt(socket.IPPROTO_TCP, socket.TCP_CONGESTION, 16).rstrip(b"\0").decode()
        sock.shutdown(socket.SHUT_WR)
    half_time, half_acked = halfway
    result = {
        "selected": selected,
        "goodput_mbit": info["bytes_acked"] * 8 / 1e6 / (finish - start),
        "steady_mbit": (info["bytes_acked"] - half_acked) * 8 / 1e6 / (finish - half_time),
        "retrans_pct": 100 * info["bytes_retrans"] / info["bytes_sent"] if info["bytes_sent"] else 0,
        "srtt_ms": info["rtt_us"] / 1000,
        "min_rtt_ms": info["min_rtt_us"] / 1000,
    }
    result.update(extra)
    print(json.dumps(result), flush=True)


def receive():
    with socket.socket() as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("0.0.0.0", PORT))
        listener.listen(1)
        print("ready", flush=True)
        connection, _ = listener.accept()
        total = 0
        with connection:
            while chunk := connection.recv(1 << 20):
                total += len(chunk)
    print(json.dumps({"bytes": total}), flush=True)


def measure(congestion_control, seconds):
    script = os.path.abspath(__file__)
    receiver = subprocess.Popen(["ip", "netns", "exec", "bbrv3-rcv", sys.executable, script, "--receive"],
                                stdout=subprocess.PIPE, text=True)
    try:
        if receiver.stdout.readline().strip() != "ready":
            raise RuntimeError("the receiver did not start")
        sender = subprocess.run(["ip", "netns", "exec", "bbrv3-snd", sys.executable, script,
                                 "--send", congestion_control, "--seconds", str(seconds)],
                                stdout=subprocess.PIPE, text=True, check=True, timeout=seconds + 120)
        received = json.loads(receiver.communicate(timeout=120)[0])
    finally:
        if receiver.poll() is None:
            receiver.kill()
    result = json.loads(sender.stdout)
    if result["selected"] != congestion_control:
        raise RuntimeError(f"the socket used {result['selected']} instead of {congestion_control}")
    if received["bytes"] <= 0:
        raise RuntimeError("the receiver got no data")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--receive", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--send", metavar="CC", help=argparse.SUPPRESS)
    parser.add_argument("--seconds", type=float, default=20, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.receive:
        receive()
        return
    if args.send:
        send(args.send, args.seconds)
        return

    kernel = os.uname().release
    try:
        offloads = setup()
        for name, rate_mbit, rtt_ms, loss_pct, buffer_bdp, seconds in PROFILES:
            shape(rate_mbit, rtt_ms, loss_pct, buffer_bdp)
            for congestion_control in CONGESTION_CONTROLS:
                result = measure(congestion_control, seconds)
                fields = {
                    "kernel": kernel,
                    "cc": congestion_control,
                    "bbr_version": result.get("bbr_version", "-"),
                    "profile": name,
                    "rate_mbit": rate_mbit,
                    "rtt_ms": rtt_ms,
                    "loss_pct": loss_pct,
                    "buffer_bdp": buffer_bdp,
                    "seconds": seconds,
                    "goodput_mbit": f"{result['goodput_mbit']:.1f}",
                    "steady_mbit": f"{result['steady_mbit']:.1f}",
                    "retrans_pct": f"{result['retrans_pct']:.2f}",
                    "srtt_ms": f"{result['srtt_ms']:.1f}",
                    "min_rtt_ms": f"{result['min_rtt_ms']:.1f}",
                    "bbr_bw_mbit": f"{result['bbr_bw_mbit']:.1f}" if "bbr_bw_mbit" in result else "-",
                    "offloads": offloads,
                }
                print("VM_NETWORK_RESULT: " + " ".join(f"{key}={value}" for key, value in fields.items()),
                      flush=True)
    except subprocess.CalledProcessError as error:
        sys.exit(f"{' '.join(error.cmd)} failed: {(error.stderr or '').strip()}")
    finally:
        teardown()


if __name__ == "__main__":
    main()
