# BBRv3 补丁等同性审计（2026-09-05）

## 审计问题

`patches/bbrv3-ubuntu-7.0.0-30.30.patch`（移植来源：byJoey/Actions-bbr-v3 提交 `d6bd606b`）与 Google 官方 BBRv3 实现（google/bbr `v3` 分支，基于 Linux 6.13.7）在算法语义上是否一致，第三方是否夹带了官方实现之外的修改。

## 方法

1. 逐文件下载 Google v3 分支与原版 stable v6.13.7（gregkh/linux）的 16 个受影响文件，计算官方精确增量。
2. 解析移植补丁，得到相对 Ubuntu 7.0.0-30.30 基线的逐文件增量。
3. 增量对增量比对新增内容覆盖度；并用本地 Ubuntu 基线树重构"打补丁后的最终文件"，与 Google v3 最终文件直接比对（重点 `tcp_bbr.c`）。
4. 对每处不重合的行人工定性。

## 结论

**未发现任何算法语义偏差。** 全部差异属于三类：Linux 7.0 API 演进适配、文件位置搬迁、以及一项已记录的刻意裁剪。BBRv3 控制律本体（`tcp_bbr.c`，2408 行）与 Google 官方最终文件实质等同（仅 2 行缺失 / 3 行多出，均为下述 ECN API 适配）。

## 差异明细与定性

| 位置 | Google v3 | 移植版 | 定性 |
|---|---|---|---|
| `tcp_bbr.c` `bbr_ecn_low` | `(tcp_sk(sk)->ecn_flags & TCP_ECN_OK) && (... & TCP_ECN_LOW)` | `tcp_ecn_mode_any(tp) && (... & TCP_ECN_LOW)` | 7.0 以 AccECN 模式状态机取代 `TCP_ECN_OK` 位；语义等价 |
| `tcp_cong.c` | `INET_ECN_xmit(sk)` | `INET_ECN_xmit_ect_1_negotiation(sk)` + 新 include | 7.0 ECN 发送 API 演进（ECT(1) 协商） |
| `bpf_tcp_ca.c` | `__tcp_send_ack(..., rcv_nxt)` | `__tcp_send_ack(..., rcv_nxt, 0)` | 7.0 增加第三参数 |
| `include/net/tcp.h` | `TCP_ECN_LOW 16`、`TCP_ECN_ECT_PERMANENT 32` | `BIT(5)`、`BIT(6)` | `ecn_flags` 位空间因 AccECN 扩张而重编号，符号化使用，全局一致 |
| `include/uapi/linux/tcp.h`、`tcp.c` | `TCPI_OPT_ECN_LOW 128`（tcpi_options） | `TCPI_OPT2_ECN_LOW BIT(0)`（tcpi_options2） | 7.0 tcp_info 选项位耗尽，新增 options2 字段；观测语义等价 |
| `tcp_output.c` / `tcp_ecn.h` | ECN-low-on-SYN 逻辑在 `tcp_output.c` | 移至 `include/net/tcp_ecn.h`（6.13 后上游拆分出的文件） | 文件搬迁，逐行对应 |
| `tcp_output.c` | `tcp_tso_autosize(..., int min_tso_segs)` 原型导出 | 未导出 | 7.0 改变了该函数签名 |
| `tcp_output.c` / `tcp_input.c` | `tcp_set_tx_in_flight` 原型在 tcp.h | 函数体为 tcp_output.c 内 static，配套 rate_sample 记账（`rs->tx_in_flight`、`rs->prior_lost`、`tcp_stamp32_us_delta`） | 7.0 重构 tx 记账结构后的等价实现 |
| `include/linux/tcp.h` | `u32 recvmsg_inq : 1` | 缩进/位域布局不同 | 7.0 位域重排 |
| `net/ipv4/Kconfig` | 额外保留 `TCP_CONG_BBR1`（仅测试用途） | 未提供 BBRv1 配置项 | **刻意裁剪**：本内核仅提供 BBRv3（见下） |

## 已记录的行为差异（非算法差异）

移植版不提供 Google 树中为对比测试保留的 BBRv1 配置项（`TCP_CONG_BBR1`）。本内核的 `tcp_bbr` 模块仅含 BBRv3。此为产品决策而非算法改动，已在此记录。

## 局限

- 行集合比对不感知顺序；顺序等价性由"补丁精确应用 + 全量编译 + QEMU 行为门禁 + p1 真机运行证据"链路覆盖。
- `include/net/tcp_ecn.h` 在 6.13.7 不存在，无法做文件级直接比对，其内容已与 Google `tcp_output.c` 增量逐行对照。
- 共享大文件（`tcp_input.c` 等）中 6.13→7.0 的上游自身演进不属于本审计对象，已通过增量级比对排除。

## 复核数据

- 官方基线：gregkh/linux `v6.13.7`；官方实现：google/bbr `v3`（tag `bbrv3-2025-03-18`，Makefile 6.13.7）
- 移植基线：Ubuntu `Ubuntu-7.0.0-30.30`（本地验证树 `work/patch-verify-ubuntu-7.0.0-30.30`）
- 补丁 SHA-256：`e4bd6d0b992a94c315caf85ff91b2851909f148337327714277df1970b292039`
- 比对产物：`%TEMP%\bbrv3-audit\compare-report.txt`、`final-compare.txt`
