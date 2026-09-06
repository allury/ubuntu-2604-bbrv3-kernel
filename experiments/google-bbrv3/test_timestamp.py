"""Compile the actual added helper in isolation; not a full kernel compile."""
import pathlib
import re
import subprocess
import tempfile

patch = pathlib.Path(__file__).with_name("patches") / "0002-tcp-rate-skb-timestamps.patch"
added = "\n".join(line[1:] for line in patch.read_text().splitlines()
                  if line.startswith("+") and not line.startswith("+++"))
match = re.search(r"static inline u32 tcp_stamp32_us_delta\(u32 t1, u32 t0\)\n\{.*?\n\}", added, re.S)
if not match:
    raise SystemExit("Actual helper missing from patch")
source = """
#include <stdint.h>
#include <assert.h>
typedef uint32_t u32;
typedef int32_t s32;
#define max_t(type, a, b) ((type)(a) > (type)(b) ? (type)(a) : (type)(b))
""" + match.group() + """
int main(void) {
    assert(tcp_stamp32_us_delta(20, 10) == 10);
    assert(tcp_stamp32_us_delta(10, 20) == 0);
    assert(tcp_stamp32_us_delta(0, 0) == 0);
    assert(tcp_stamp32_us_delta(0x10U, 0xfffffff0U) == 32);
    assert(tcp_stamp32_us_delta(0xfffffff0U, 0x10U) == 0);
    assert(tcp_stamp32_us_delta(0x7fffffffU, 0) == 0x7fffffffU);
    assert(tcp_stamp32_us_delta(0x80000000U, 0) == 0);
    return 0;
}
"""
with tempfile.TemporaryDirectory(prefix="bbr-timestamp-test-") as tmp:
    path = pathlib.Path(tmp)
    (path / "test.c").write_text(source)
    subprocess.run(["gcc", "-std=gnu11", "-Wall", "-Wextra", "-Werror",
                    str(path / "test.c"), "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
print("PASS: extracted timestamp helper, seven arithmetic boundary checks")
