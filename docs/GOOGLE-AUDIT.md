# Google 对照审计

本文逐项审阅 `patches/bbrv3-ubuntu-7.0.0-30.30.patch` 与其所依据的 Google 官方 BBRv3 之间的差异。审阅依据的机器报告 [`google-audit/bbrv3-ubuntu-7.0.0-30.30.txt`](google-audit/bbrv3-ubuntu-7.0.0-30.30.txt) 由 `scripts/audit-google-bbrv3.sh` 生成，输入全部固定到提交，任何人重新运行都应得到逐字节相同的结果；方法见 [补丁策略](../patches/README.md#google-对照审计)。

## 结论

BBRv3 算法与 Google 官方实现一致，没有发现第三方夹带的额外改动。

- 算法本体 `tcp_bbr.c` 与 Google 的最终文件只差一个函数：判断连接能否使用 ECN 时，改用 Linux 7.0 的 ECN 模式接口。
- 其余差异都属于以下两类：一是为适配 Linux 7.0 必须做的改动，例如常量重新编号、代码随 Linux 搬到新位置、接口改名；二是有意不移植的 Google 测试辅助内容。
- 发现一处移植没有带上的 Linux 改动：Linux 7.0 给 `tcp_bbr.c` 中两处 `snd_ssthresh` 写入加了 `WRITE_ONCE()`。这是并发访问标注，不涉及算法，建议下次修订补丁时补上，不必为它单独发版。

## 审计对象

| 项目 | 内容 |
| --- | --- |
| 补丁 | `bbrv3-ubuntu-7.0.0-30.30.patch`，SHA-256 `e4bd6d0b992a94c315caf85ff91b2851909f148337327714277df1970b292039` |
| 移植基线 | Ubuntu 标签 `Ubuntu-7.0.0-30.30`，提交 `d974a4063f5c03c13b4f241a9ab511750e0b9f12` |
| Google 版本 | [google/bbr](https://github.com/google/bbr) 标签 `bbrv3-2025-03-18`，提交 `90210de4b779d40496dee0b89081780eeddf2a60`；审计时 `v3` 分支也指向这个提交 |
| Google 基线 | Linux `v6.13.7`（提交 `648e04a805652f513af04b47035cde896addf9b0`，kernel.org 稳定版仓库），Google 版本在其上加 27 个提交 |
| 改动文件 | Google 31 个（其中 13 个是测试和说明文件），本补丁 16 个 |

## 算法本体 `tcp_bbr.c`

Google 用完整的 BBRv3 实现替换了这个文件，因此按最终文件比较。本补丁的文件与 Google 的只有一处不同：

```c
/* Google（基于 Linux 6.13.7） */
return (tcp_sk(sk)->ecn_flags & TCP_ECN_OK) &&
       (tcp_sk(sk)->ecn_flags & TCP_ECN_LOW);

/* 本补丁（Linux 7.0） */
return tcp_ecn_mode_any(tp) && (tp->ecn_flags & TCP_ECN_LOW);
```

Linux 7.0 为支持 AccECN，用"ECN 模式"取代了 `TCP_ECN_OK` 标志位，`tcp_ecn_mode_any()` 在连接处于经典 ECN 或 AccECN 模式时为真，对应 6.13 中 `TCP_ECN_OK` 的含义，只是多包含了 7.0 新增的 AccECN。因此在本补丁中，使用 AccECN 的连接也算作可以使用 ECN。这个函数只在连接启用了 ECN low 时起作用；ECN low 由路由特性 `ecn_low` 开启，默认不启用。

Linux 在 6.13.7 与 7.0 之间对原 BBRv1 文件的改动，只有两处 `snd_ssthresh` 写入改为 `WRITE_ONCE()`。见下文"移植没有带上的 Linux 改动"。

## 为适配 Linux 7.0 所做的改动

| 位置 | Google（6.13.7） | 本补丁（7.0） | 原因 |
| --- | --- | --- | --- |
| `TCP_ECN_LOW`、`TCP_ECN_ECT_PERMANENT`（`include/net/tcp.h`） | 16、32 | `BIT(5)`、`BIT(6)` | 7.0 中 16 即 `BIT(4)`，已被 `TCP_ECN_MODE_ACCECN` 占用；`BIT(5)`、`BIT(6)` 在 7.0 的 8 位 `ecn_flags` 中空闲 |
| `TCP_CONG_WANTS_CE_EVENTS`（`include/net/tcp.h`） | 0x4 | `BIT(5)` | 7.0 中 0x4 即 `BIT(2)`，已被 `TCP_CONG_NEEDS_ACCECN` 占用，`BIT(0)` 至 `BIT(4)` 都已使用；两边都把它加入 `TCP_CONG_MASK` |
| ECN low 在 `tcp_info` 中的标志（`include/uapi/linux/tcp.h`、`net/ipv4/tcp.c`） | `tcpi_options` 的 128 | `tcpi_options2` 的 `BIT(0)` | 7.0 中 128 已是 `TCPI_OPT_TFO_CHILD`；`tcpi_options2` 是 7.0 新增的字段，尚无其他标志 |
| 速率采样的记账（Google 改在 `tcp_rate.c`） | `tcp_rate.c` | `tcp_input.c`、`tcp_output.c` | 7.0 删除了 `tcp_rate.c`，把其中的函数并入这两个文件；`tcp_set_tx_in_flight()` 随之成为 `tcp_output.c` 的内部函数，`tcp.h` 不再声明它 |
| SYN 报文上的 ECN low（Google 改在 `tcp_output.c`） | `tcp_output.c` | `include/net/tcp_ecn.h` | 7.0 把 ECN 相关函数移到了 `tcp_ecn.h` |
| `tcp_set_tx_in_flight()` 的告警信息 | `tp->snd_cwnd` | `tcp_snd_cwnd(tp)` | 7.0 统一用访问函数读取拥塞窗口，取到的值相同 |
| `fast_ack_mode` 位（`include/linux/tcp.h`） | 把 `recvmsg_inq` 所在位域改为 32 位后加入 | 直接加入 7.0 已有的位域 | 7.0 的结构体布局不同 |
| 换行、缩进、注释文字、所在函数改名 | | | 只影响排版，机器报告的"Changes in order"一节逐处列出 |

`tcp_cong.c`、`bpf_tcp_ca.c`、`tcp_minisocks.c`、`tcp_timer.c`、`inet_connection_sock.h`、`inet_diag.h`、`rtnetlink.h` 七个文件的改动在忽略空白后与 Google 相同，顺序也相同。

表中各标志位的占用情况，都由补丁里取自 Ubuntu 源码的上下文行确认。

ECN low 标志换了位置，因此对用户态工具有一个影响：Google 附带的 iproute2 补丁按 `tcpi_options` 的 128 位显示 `ecn_low`，而在本内核上这一位表示 `TFO_CHILD`，所以那个补丁不能直接配合本内核使用。只有启用了 `ecn_low` 路由特性、又要用 `ss` 查看它的场景才会遇到。

## 有意不移植的内容

- **BBRv1 测试副本：** Google 为对比测试保留的 `net/ipv4/tcp_bbr1.c`（非空行 1056 行），以及 `TCP_CONG_BBR1`、`DEFAULT_BBR1` 两个配置项、`Makefile` 条目，还有只为它导出的 `tcp_tso_autosize()`。本内核的 `bbr` 模块只提供 BBRv3；需要对比 BBRv1 时，用官方内核即可。
- **测试和说明文件：** `README.md`、`config.gce`、`gce-install.sh`、`gtests/` 下的测试脚本与 iproute2 补丁，以及 `.gitignore` 中的两行。它们不进入内核。

## 移植没有带上的 Linux 改动

Linux 在 6.13.7 之后，把 `tcp_bbr.c` 中 `bbr_check_drain()` 和 `bbr_init()` 对 `snd_ssthresh` 的两处直接赋值改成了 `WRITE_ONCE()`。原因是这个字段可能在不持有套接字锁时被读取，需要告诉编译器和并发检测工具这里存在无锁读取。

Google 的 BBRv3 文件基于 6.13.7，在同样的两个函数里写 `snd_ssthresh`，没有这个标注。本补丁整体采用 Google 的文件，所以也没有。Google 在代码注释中说明，BBR 写 `snd_ssthresh` 只是为了供监控读取，算法本身不使用它。

**建议：** 下次因为其他原因修订补丁时，在这两处补上 `WRITE_ONCE()`；不必为它单独发版。

## 方法的局限

- 行比较能发现两边改动的每一处不同，但不能证明语义等价。机器报告最后一节按顺序比较，补充了改动所在的位置和先后。
- Linux 7.0 新增或改写的代码路径是否也需要 BBRv3 的记账调整，这种比较无法发现。例如新的拆分或合并数据包的函数，是否也要像 `tcp_fragment()` 那样维护 `tx.in_flight`，属于 [补丁策略](../patches/README.md) 中"Ubuntu 接口与语义兼容性审查"的范围，仍需单独审查。
- 完整编译、QEMU 冒烟、云镜像虚拟机安装验收和网络行为对比，从运行层面补充证据。它们同样不能证明所有场景都正确。

## Google 的更新版本

Google 在 2026-09-16 推送了分支 `bbr-v3-2026-09-16-01`，基于 Linux 7.1-rc5（net-next），与本审计所依据的 2025-03-18 版有较大不同：

- BBRv3 改为独立文件 `tcp_bbr3.c`，模块名 `bbr3`；`tcp_bbr.c` 保持 BBRv1 原样。
- 与 2025-03-18 版的 `tcp_bbr.c` 相比，约 1150 行不同：去掉了 ECN（含 ECN low）和 PLB；增加了丢包撤销时的状态转换（`undo_state`）、DRAIN 阶段的轮数计数等。
- 如果以后跟进这个版本，拥塞控制名会从 `bbr` 变为 `bbr3`。服务器上现有的 `tcp_congestion_control = bbr` 配置届时会选中 BBRv1，需要改名或做兼容处理。

本补丁以 2025-03-18 版为准。是否跟进新版本需要单独决定，并重新移植和审计。审计工作流每次运行都会列出比参考版本更新的 Google 分支和标签。
