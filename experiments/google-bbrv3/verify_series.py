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
            result = subprocess.run(
                ["git", "-c", "safe.directory=" + str(repo), "-C", str(repo), *argv],
                env=env, capture_output=True)
            if result.returncode:
                raise SystemExit(result.stderr.decode(errors="replace"))
            return result.stdout

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
        send = git("show", ":net/ipv4/tcp_output.c").decode()
        required = {
            "send snapshot and loss counter": (send, [
                "static void tcp_set_tx_in_flight(",
                "in_flight = tcp_packets_in_flight(tp) + tcp_skb_pcount(skb);",
                "in_flight = TCPCB_IN_FLIGHT_MAX;",
                "TCP_SKB_CB(skb)->tx.lost\t\t= tp->lost;",
                "tcp_init_tso_segs(skb, mss_now);\n\t\t\ttcp_set_tx_in_flight(sk, skb);",
            ]),
            "ACK sample fields": (ack, [
                "rs->tx_in_flight     = scb->tx.in_flight;",
                "rs->prior_lost\t     = scb->tx.lost;",
                "rs->lost        = tp->lost - rs->prior_lost;",
                "rs->losses = lost;",
                "tcp_newly_delivered(sk, delivered, ecn_count, flag)",
                "rs.is_ece = !!(flag & FLAG_ECE);\n\ttcp_rate_gen(",
            ]),
        }
        for label, (content, fragments) in required.items():
            if not all(fragment in content for fragment in fragments):
                raise SystemExit(label + " check failed")
        if send.count("tcp_set_tx_in_flight(sk, skb);") != 2:
            raise SystemExit("Expected ordinary and repair send call sites")
        if "tp->lost += tcp_skb_pcount(skb);\n\tif (ca_ops->skb_marked_lost)" not in ack:
            raise SystemExit("Loss callback must follow loss counter update")
        if "void (*skb_marked_lost)(struct sock *sk, const struct sk_buff *skb);" not in header:
            raise SystemExit("Loss callback declaration missing")
        for fragment in ("TCP_SKB_CB(skb)->tx.in_flight -= pcount;",
                         "TCP_SKB_CB(prev)->tx.in_flight += pcount;"):
            if fragment not in ack:
                raise SystemExit("Merge accounting missing")
        if "inflight_prev = TCP_SKB_CB(skb)->tx.in_flight - old_factor;" not in send:
            raise SystemExit("Split accounting missing")
        import re
        flags = re.findall(r"^#define (TCP_CONG_\w+)\s+BIT\((\d+)\)", header, re.M)
        values = dict(flags)
        if values.get("TCP_CONG_WANTS_CE_EVENTS") != "5":
            raise SystemExit("CE request must use the free Ubuntu bit")
        if len(set(values.values())) != len(values):
            raise SystemExit("Congestion-control flag collision")
        if values.get("TCP_CONG_NEEDS_ACCECN") != "2":
            raise SystemExit("Ubuntu AccECN flag changed")
        if ack.count("tcp_ca_wants_ce_events(sk)") != 2:
            raise SystemExit("Expected two CE notification predicates")
        bpf = git("show", ":net/ipv4/bpf_tcp_ca.c").decode()
        bbr = git("show", ":net/ipv4/tcp_bbr.c").decode()
        for content in (header, bpf, bbr, send):
            if "(*min_tso_segs)" in content or ".min_tso_segs" in content or "ca_ops->min_tso_segs" in content:
                raise SystemExit("Stale TSO callback interface")
        if ".tso_segs = bpf_tcp_ca_tso_segs," not in bpf:
            raise SystemExit("BPF TSO stub missing")
        if "READ_ONCE(sock_net(sk)->ipv4.sysctl_tcp_min_tso_segs)" not in send:
            raise SystemExit("Fallback sysctl read protection lost")
        core = git("show", ":net/ipv4/tcp.c").decode()
        cong = git("show", ":net/ipv4/tcp_cong.c").decode()
        if "tp->fast_ack_mode = 0;" not in core or "tcp_sk(sk)->fast_ack_mode = 0;" not in cong:
            raise SystemExit("fast ACK reset/init missing")
        if "tp->fast_ack_mode == 1 ||" not in ack:
            raise SystemExit("fast ACK predicate missing")
        if "tp->tlp_orig_data_app_limited = TCP_SKB_CB(skb)->tx.is_app_limited;\n\tif (__tcp_retransmit_skb" not in send:
            raise SystemExit("TLP state must be captured before retransmit")
        if ack.count("tcp_process_tlp_ack(sk, ack, flag, &rs);") != 2:
            raise SystemExit("Both TLP ACK paths must receive the sample")
        if "tcp_process_tlp_ack(sk, ack, flag);" in ack:
            raise SystemExit("Stale TLP ACK caller")
        if "tcp_ca_event(sk, CA_EVENT_TLP_RECOVERY);\n\t\ttcp_init_cwnd_reduction(sk);" not in ack:
            raise SystemExit("TLP notification ordering incorrect")
        if "rs->is_acking_tlp_retrans_seq = 1;" not in ack:
            raise SystemExit("TLP ambiguous ACK marking missing")
        ecn = git("show", ":include/net/tcp_ecn.h").decode()
        child = git("show", ":net/ipv4/tcp_minisocks.c").decode()
        route = git("show", ":include/uapi/linux/rtnetlink.h").decode()
        if "#define\tTCP_ECN_LOW\t\tBIT(5)" not in header:
            raise SystemExit("Low ECN must not overlap AccECN")
        if "#define\tTCP_ECN_MODE_ACCECN\tBIT(4)" not in header:
            raise SystemExit("AccECN mode changed")
        if ecn.count("tcp_set_ecn_low_from_dst(sk, dst);") != 1 or child.count("tcp_set_ecn_low_from_dst(sk, dst);") != 1:
            raise SystemExit("Active/passive low ECN route initialization missing")
        if "tcp_ecn_mode_set(tp, TCP_ECN_MODE_PENDING);" not in ecn:
            raise SystemExit("AccECN SYN negotiation lost")
        if "#define RTAX_FEATURE_ECN_LOW\t\t(1 << 5)" not in route:
            raise SystemExit("Low ECN route flag missing")
        print(json.dumps(dict(base=BASE, patches=checks, source_order_checks="passed",
                              complete_bbrv3_port=False, compiled=False), indent=2))
        print(git("diff", "--cached", "--stat", BASE).decode())


if __name__ == "__main__":
    main()
