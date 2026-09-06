"""Test the actual added CE predicate using fixed Ubuntu flag definitions."""
import pathlib
import re
import subprocess
import tempfile

patch = pathlib.Path(__file__).with_name("patches") / "0009-tcp-ce-events.patch"
added = "\n".join(line[1:] for line in patch.read_text().splitlines()
                  if line.startswith("+") and not line.startswith("+++"))
definition = re.search(r"^#define TCP_CONG_WANTS_CE_EVENTS.*$", added, re.M).group()
helper = re.search(r"static inline bool tcp_ca_wants_ce_events.*?\n\}", added, re.S).group()
source = r"""
#include <stdbool.h>
#include <assert.h>
#define BIT(n) (1U << (n))
#define TCP_CONG_NEEDS_ECN BIT(1)
#define TCP_CONG_NEEDS_ACCECN BIT(2)
struct tcp_congestion_ops { unsigned flags; };
struct inet_connection_sock { struct tcp_congestion_ops *icsk_ca_ops; };
struct sock { struct inet_connection_sock icsk; };
#define inet_csk(sk) (&(sk)->icsk)
""" + definition + "\n" + helper + r"""
int main(void) {
    struct tcp_congestion_ops ops = {0};
    struct sock sk = {{&ops}};
    assert((TCP_CONG_WANTS_CE_EVENTS & 31U) == 0);
    for (unsigned flags = 0; flags < 64; ++flags) {
        ops.flags = flags;
        assert(tcp_ca_wants_ce_events(&sk) ==
               !!(flags & (BIT(1) | BIT(5))));
    }
    return 0;
}
"""
with tempfile.TemporaryDirectory(prefix="bbr-ce-flags-") as tmp:
    root = pathlib.Path(tmp)
    (root / "test.c").write_text(source)
    subprocess.run(["gcc", "-std=gnu11", "-Wall", "-Wextra", "-Werror",
                    str(root / "test.c"), "-o", str(root / "test")], check=True)
    subprocess.run([str(root / "test")], check=True)
print("PASS: CE predicate over all 64 combinations; Ubuntu flag bits preserved")
