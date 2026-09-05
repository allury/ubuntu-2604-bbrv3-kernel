#!/usr/bin/env python3
"""Construct the self-ported BBRv3 tree for one Ubuntu kernel source version.

Inputs (directory layout, supplied by the caller):
  base/     Ubuntu kernel source tree at the exact released tag
  vanilla/  pristine mainline/stable tree matching Google's bbr v3 base
  google/   Google bbr v3 branch checkout

Output:
  ported/   the 16 BBRv3 files ported onto the Ubuntu base
  porting-report.txt  which hunks were auto-placed, adapted, or dropped

Method: compute the official Google delta per file (difflib), then apply
each hunk onto the Ubuntu base by exact context match. Hunks that cannot
be placed exactly are resolved by the explicit ADAPTATIONS rules below;
anything still unresolved is a hard failure. tcp_bbr.c is taken verbatim
from Google v3 with the documented ECN-mode adaptation.

This script is deterministic and stdlib-only.
"""
import difflib
import pathlib
import sys

FILES = [
    "include/linux/tcp.h",
    "include/net/inet_connection_sock.h",
    "include/net/tcp.h",
    "include/net/tcp_ecn.h",
    "include/uapi/linux/inet_diag.h",
    "include/uapi/linux/rtnetlink.h",
    "include/uapi/linux/tcp.h",
    "net/ipv4/Kconfig",
    "net/ipv4/bpf_tcp_ca.c",
    "net/ipv4/tcp.c",
    "net/ipv4/tcp_bbr.c",
    "net/ipv4/tcp_cong.c",
    "net/ipv4/tcp_input.c",
    "net/ipv4/tcp_minisocks.c",
    "net/ipv4/tcp_output.c",
    "net/ipv4/tcp_timer.c",
]

# Adaptation rules applied while splicing Google-added lines onto the
# Ubuntu base. Each is justified by docs/PATCH-AUDIT.md.
LINE_SUBSTITUTIONS = [
    # AccECN replaced the TCP_ECN_OK flag check with a mode helper.
    ("return (tcp_sk(sk)->ecn_flags & TCP_ECN_OK) &&",
     "const struct tcp_sock *tp = tcp_sk(sk);"),
    ("       (tcp_sk(sk)->ecn_flags & TCP_ECN_LOW);",
     "return tcp_ecn_mode_any(tp) && (tp->ecn_flags & TCP_ECN_LOW);"),
    # ECN transmit helper was renamed upstream after 6.13.
    ("INET_ECN_xmit(sk);", "INET_ECN_xmit_ect_1_negotiation(sk);"),
    # __tcp_send_ack grew a third argument.
    ("__tcp_send_ack((struct sock *)tp, rcv_nxt);",
     "__tcp_send_ack((struct sock *)tp, rcv_nxt, 0);"),
    # ecn_flags bit space was renumbered after AccECN additions.
    ("#define\tTCP_ECN_LOW\t\t16", "#define\tTCP_ECN_LOW\t\tBIT(5)"),
    ("#define\tTCP_ECN_LOW\t\t32", "#define\tTCP_ECN_LOW\t\tBIT(5)"),
    ("#define TCP_ECN_LOW\t\t16", "#define TCP_ECN_LOW\t\tBIT(5)"),
    ("#define TCP_ECN_LOW\t\t32", "#define TCP_ECN_LOW\t\tBIT(5)"),
    ("#define\tTCP_ECN_ECT_PERMANENT\t32", "#define\tTCP_ECN_ECT_PERMANENT\tBIT(6)"),
    ("#define TCP_ECN_ECT_PERMANENT\t32", "#define TCP_ECN_ECT_PERMANENT\tBIT(6)"),
    ("#define TCP_CONG_WANTS_CE_EVENTS\t0x4", "#define TCP_CONG_WANTS_CE_EVENTS\tBIT(5)"),
    # tcp_info moved new option bits to the options2 field.
    ("#define TCPI_OPT_ECN_LOW\t128 /* Low-latency ECN enabled at conn init */",
     "#define TCPI_OPT2_ECN_LOW\tBIT(0) /* Low-latency ECN enabled at conn init */"),
    ("info->tcpi_options |= TCPI_OPT_ECN_LOW;",
     "info->tcpi_options2 |= TCPI_OPT2_ECN_LOW;"),
    # 7.0 bitfield layout for recvmsg_inq.
    ("u32\trecvmsg_inq : 1,/* Indicate # of bytes in queue upon recvmsg */",
     "\trecvmsg_inq : 1,/* Indicate # of bytes in queue upon recvmsg */"),
    ("u8\trecvmsg_inq : 1,/* Indicate # of bytes in queue upon recvmsg */",
     "\trecvmsg_inq : 1,/* Indicate # of bytes in queue upon recvmsg */"),
]

# Google-added blocks that must NOT be carried into the Ubuntu port,
# with reasons recorded in the report.
DROPPED_LINE_PREFIXES = [
    # 6.13-era tcp_tso_autosize prototype; the 7.0 signature differs and
    # the port keeps the helper static.
    "u32 tcp_tso_autosize(const struct sock *sk, unsigned int mss_now,",
    "int min_tso_segs);",
    "int min_tso_segs)",
    # The port defines tcp_set_tx_in_flight as static in tcp_output.c;
    # carrying Google's extern prototype into tcp.h would not compile.
    "void tcp_set_tx_in_flight(struct sock *sk, struct sk_buff *skb);",
]

# Deliberate product decision, scoped to net/ipv4/Kconfig only: no BBRv1
# testing configuration is carried over from Google's tree.
KCONFIG_BBR1_MARKERS = (
    "config TCP_CONG_BBR1",
    'tristate "BBRv1 TCP"',
    "BBRv1, for testing.",
    "config DEFAULT_BBR1",
    'bool "BBR1" if TCP_CONG_BBR1=y',
)

report = []


def note(kind, path, detail):
    report.append(f"{kind}\t{path}\t{detail}")


def read(p):
    return p.read_text(encoding="utf-8", newline="").splitlines()


def write(p, lines):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="")


def substitute(added_lines, path):
    out = []
    for line in added_lines:
        replaced = line
        for old, new in LINE_SUBSTITUTIONS:
            if line.strip() == old.strip():
                replaced = new
                note("adapt", path, f"{old.strip()!r} -> {new.strip()!r}")
                break
        if any(replaced.startswith(prefix) for prefix in DROPPED_LINE_PREFIXES):
            note("drop", path, f"upstream-signature divergence: {replaced.strip()!r}")
            continue
        if path.endswith("Kconfig") and any(marker in replaced for marker in KCONFIG_BBR1_MARKERS):
            note("drop", path, f"BBRv1 testing config omitted: {replaced.strip()!r}")
            continue
        out.append(replaced)
    return out


def parse_hunks(diff_lines):
    """Yield (old_start, old_lines, new_lines) from a unified diff body."""
    hunks = []
    old = new = []
    ostart = None
    for line in diff_lines:
        if line.startswith("@@"):
            if ostart is not None:
                hunks.append((ostart, old, new))
            ostart = int(line.split()[1].split(",")[0])
            old, new = [], []
        elif line.startswith("-"):
            old.append(line[1:])
        elif line.startswith("+"):
            new.append(line[1:])
        elif line.startswith((" ", "\t")):
            old.append(line[1:])
            new.append(line[1:])
    if ostart is not None:
        hunks.append((ostart, old, new))
    return hunks


def substitute_line(line):
    """Pure single-line application of the adaptation mapping (no notes)."""
    for old, new in LINE_SUBSTITUTIONS:
        if line.strip() == old.strip():
            return new
    return line


def norm(line):
    return " ".join(line.split())


def block_matches(window, old):
    """True when a base window corresponds to a 6.13-era hunk context,
    accounting for the documented adaptations and whitespace drift."""
    if window == old:
        return True
    sub_old = [substitute_line(l) for l in old]
    if window == sub_old:
        return True
    if [norm(l) for l in window] == [norm(l) for l in sub_old]:
        return True
    if [norm(l) for l in window] == [norm(l) for l in old]:
        return True
    return False


def apply_hunks(base_lines, hunks, path):
    """Place hunks by matching their context, in order, into base_lines."""
    result = list(base_lines)
    cursor = 0
    for ostart, old, new in hunks:
        adapted = substitute(new, path)
        if old == new:
            continue
        placed = False
        for i in range(cursor, len(result) - len(old) + 1):
            if result[i:i + len(old)] == old:
                result[i:i + len(old)] = adapted
                cursor = i + len(adapted)
                placed = True
                note("auto", path, f"hunk at base line {i + 1} ({len(new)} added lines)")
                break
        if not placed:
            for i in range(cursor, len(result) - len(old) + 1):
                if block_matches(result[i:i + len(old)], old):
                    result[i:i + len(old)] = adapted
                    cursor = i + len(adapted)
                    placed = True
                    note("adapt", path, f"adapted-context hunk at base line {i + 1}")
                    break
        if not placed:
            raise SystemExit(
                f"UNRESOLVED hunk in {path}: old={old!r}")
    return result


def port_tcp_bbr(google_lines):
    text = "\n".join(google_lines)
    old = ("return (tcp_sk(sk)->ecn_flags & TCP_ECN_OK) &&\n"
           "\t       (tcp_sk(sk)->ecn_flags & TCP_ECN_LOW);")
    new = ("const struct tcp_sock *tp = tcp_sk(sk);\n"
           "\treturn tcp_ecn_mode_any(tp) && (tp->ecn_flags & TCP_ECN_LOW);")
    if text.count(old) != 1:
        raise SystemExit(f"tcp_bbr.c ECN adaptation anchor mismatch: {text.count(old)}")
    note("adapt", "net/ipv4/tcp_bbr.c", "bbr_ecn_low check -> tcp_ecn_mode_any")
    return text.replace(old, new).splitlines()


def main():
    if len(sys.argv) != 5:
        raise SystemExit("usage: port-bbrv3.py <base> <vanilla> <google> <out>")
    base_root, vanilla_root, google_root, out_root = map(pathlib.Path, sys.argv[1:])

    for rel in FILES:
        base_p = base_root / rel
        vanilla_p = vanilla_root / rel
        google_p = google_root / rel

        if rel == "net/ipv4/tcp_bbr.c":
            out = port_tcp_bbr(read(google_p))
            note("google-verbatim", rel, "Google v3 tcp_bbr.c + ECN adaptation")
            write(out_root / rel, out)
            continue

        if rel == "include/net/tcp_ecn.h":
            # File exists only on the Ubuntu side; Google's equivalent
            # changes live in tcp_output.c and are handled there.
            note("skip", rel, "file absent from 6.13 base; changes arrive via tcp_output.c routing below")
            continue

        vanilla_lines = read(vanilla_p) if vanilla_p.exists() else []
        google_lines = read(google_p) if google_p.exists() else []
        if not vanilla_lines or not google_lines:
            raise SystemExit(f"missing google/vanilla source for {rel}")

        if rel == "net/ipv4/tcp_output.c":
            # Google also moved tcp_ecn_send_syn logic that Ubuntu keeps in
            # include/net/tcp_ecn.h. Split those hunks out by marker.
            diff = list(difflib.unified_diff(vanilla_lines, google_lines, lineterm="", n=3))
            ecn_marker = "tcp_set_ecn_low_from_dst"
            in_ecn = False
            ecn_old, ecn_new = [], []
            plain_lines = []
            i = 0
            hunks = parse_hunks(diff)
            # Rebuild the diff without ECN-on-SYN hunks and collect them.
            kept_hunks = []
            for ostart, old, new in hunks:
                joined = "\n".join(old + new)
                if ecn_marker in joined or "tcp_ecn_send_syn" in joined:
                    ecn_old.extend(old)
                    ecn_new.extend(new)
                else:
                    kept_hunks.append((ostart, old, new))
            ported = apply_hunks(read(base_p), kept_hunks, rel)

            # Apply the ECN-on-SYN hunks to Ubuntu's tcp_ecn.h instead.
            ecn_h_path = base_root / "include/net/tcp_ecn.h"
            ecn_h = read(ecn_h_path)
            target = "\tconst struct dst_entry *dst = __sk_dst_get(sk);"
            if target not in ecn_h:
                decl = next(i for i, l in enumerate(ecn_h)
                            if "sysctl_tcp_ecn" in l) + 1
                ecn_h.insert(decl, target)
                note("adapt", "include/net/tcp_ecn.h", "hoisted dst lookup into tcp_ecn_send_syn")
            call = "\t\tif (dst)\n\t\t\ttcp_set_ecn_low_from_dst(sk, dst);"
            if call not in "\n".join(ecn_h):
                inline = "\t\tconst struct dst_entry *dst = __sk_dst_get(sk);"
                try:
                    b = ecn_h.index(inline)
                    if ecn_h[b:b + 2] == [inline, ""]:
                        del ecn_h[b:b + 2]
                        note("adapt", "include/net/tcp_ecn.h", "removed inline dst declaration")
                except ValueError:
                    pass
                anchor = "\t\t\ttcp_ecn_mode_set(tp, TCP_ECN_MODE_RFC3168);"
                a = ecn_h.index(anchor)
                ecn_h[a + 1:a + 1] = ["", call]
                note("adapt", "include/net/tcp_ecn.h", "added tcp_set_ecn_low_from_dst call")
            write(out_root / "include/net/tcp_ecn.h", ecn_h)
            note("adapt", rel, "tcp_ecn_send_syn hunks routed to include/net/tcp_ecn.h")
        else:
            diff = list(difflib.unified_diff(vanilla_lines, google_lines, lineterm="", n=3))
            ported = apply_hunks(read(base_p), parse_hunks(diff), rel)

        write(out_root / rel, ported)

    pathlib.Path("porting-report.txt").write_text("\n".join(report) + "\n", encoding="utf-8")
    print(f"ported {len(FILES)} files; {len(report)} report lines")


if __name__ == "__main__":
    main()
