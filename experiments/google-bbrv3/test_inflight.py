"""Compile actual added merge/split blocks with minimal skb stubs."""
import pathlib
import re
import subprocess
import tempfile

HERE = pathlib.Path(__file__).resolve().parent


def added(name):
    return "\n".join(line[1:] for line in (HERE / "patches" / name).read_text().splitlines()
                     if line.startswith("+") and not line.startswith("+++"))


split = added("0008-tcp-split-inflight.patch")
helper = re.search(r"static inline bool tcp_skb_tx_in_flight_is_suspicious.*?\n\}", split, re.S).group()
body = split[split.index("\t\tinflight_prev ="):]
merge = added("0007-tcp-merge-inflight.patch")
source = r"""
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
typedef uint32_t u32;
#define TCPCB_LOST 4
static int warnings;
#define WARN_ONCE(condition, ...) ((condition) ? (++warnings, 1) : 0)
struct sk_buff {
    struct { struct { u32 in_flight:20; } tx; unsigned sacked; } cb;
    int pcount;
    unsigned len;
};
#define TCP_SKB_CB(skb) (&(skb)->cb)
#define tcp_skb_pcount(skb) ((skb)->pcount)
""" + helper + """
static void split_test(struct sk_buff *skb, struct sk_buff *buff, int old_factor) {
    int inflight_prev;
""" + body + """
}
static void merge_test(struct sk_buff *prev, struct sk_buff *skb, int pcount) {
""" + merge + r"""
}
int main(void) {
    struct sk_buff first = {0}, second = {0};
    first.cb.tx.in_flight = 10;
    first.pcount = 2; second.pcount = 2;
    split_test(&first, &second, 4);
    assert(first.cb.tx.in_flight == 8 && second.cb.tx.in_flight == 10);
    assert(warnings == 0);
    first.cb.tx.in_flight = 2; first.cb.sacked = TCPCB_LOST;
    split_test(&first, &second, 4);
    assert(first.cb.tx.in_flight == 2 && second.cb.tx.in_flight == 4);
    assert(warnings == 0);
    first.cb.tx.in_flight = 2; first.cb.sacked = 0;
    split_test(&first, &second, 4);
    assert(warnings == 1);
    first.cb.tx.in_flight = 5; second.cb.tx.in_flight = 8;
    merge_test(&first, &second, 3);
    assert(first.cb.tx.in_flight == 8 && second.cb.tx.in_flight == 5);
    assert(warnings == 1);
    second.cb.tx.in_flight = 1;
    merge_test(&first, &second, 3);
    assert(first.cb.tx.in_flight == 11 && second.cb.tx.in_flight == 0);
    assert(warnings == 2);
    return 0;
}
"""
with tempfile.TemporaryDirectory(prefix="bbr-inflight-test-") as directory:
    root = pathlib.Path(directory)
    (root / "test.c").write_text(source)
    subprocess.run(["gcc", "-std=gnu11", "-Wall", "-Wextra", "-Werror",
                    str(root / "test.c"), "-o", str(root / "test")], check=True)
    subprocess.run([str(root / "test")], check=True)
print("PASS: extracted merge/split blocks; normal, lost and underflow cases")
