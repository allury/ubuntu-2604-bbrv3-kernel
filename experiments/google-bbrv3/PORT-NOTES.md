# 移植记录（进行中）

## 首批源码定位

对固定 Ubuntu 提交 d974a4063f5c03c13b4f241a9ab511750e0b9f12 检查：

- tcp_rate_gen 定义位于 net/ipv4/tcp_input.c；
- tcp_rate_skb_sent 定义位于 net/ipv4/tcp_output.c；
- 因此 Google 对 net/ipv4/tcp_rate.c 的改动需要迁移到相应实现，不能删除该补丁段或重新引入旧文件来掩盖重构。

## 官方提交分组

以下按固定 Google 历史分类，短 SHA 仅用于阅读，完整来源以 inspect.py 输出为准：

| 类别 | 提交前缀 | 审查重点 |
| --- | --- | --- |
| 采样与时间戳 | 137a508、a627517、0e6b441、3679f3b、500bcfe | app-limited、时间戳宽度、在途快照、丢包与 ECN 采样 |
| TCP 回调与分段 | f207893、88e09e2、5093de5、6642024、9163f44、4d2e564 | 丢包回调、合并拆分记账、CE 事件、TSO、ACK |
| TLP | a631934、3ee83ca、703f20a | 探测修复事件与采样状态 |
| ECN 与接口 | 9120f80、88aff89、795544c | 路由能力、重传 ECT、用户态状态 |
| 核心算法 | cb31f3d | BBRv3 状态机及 Ubuntu 新接口适配 |
| 对照模块 | f17f8f1 | 官方测试用 BBRv1 副本，不默认纳入生产配置 |

以上项目尚待逐项移植与语义复核。不得将“已定位”记为“移植完成”。

## 已实现的前两项适配

- 0001：来自 137a508，保持 ACK prior_in_flight 快照后的调用位置；定时器在处理事件、改变拥塞窗口前调用。Ubuntu 的上下文空行不同，已重新生成对应上下文。
- 0002：来自 a627517，仅将 tcp_skb_cb.tx 的两项时间戳从 u64 改为 u32，增加原始官方差值辅助函数；tcp_sock 的两项 u64 时间戳不变。两个差值调用从 tcp_rate.c 迁到 Ubuntu tcp_input.c 对应函数。
- 本地将两项按顺序应用到固定 Ubuntu 提交的临时索引，精确检查通过；额外验证调用顺序、字段宽度和两处采样调用。源码工作区及真实索引不变。
- 新增 C 辅助函数边界测试，直接提取补丁新增函数，覆盖普通、负向、零值、32 位回绕及有符号边界；由轻量 CI 执行。不是完整内核编译，也不证明长期连接正确。

这两项只是前置补丁，不包含完整 BBRv3 算法，不能安装或作为新正式版发布。

## 第三至第五项适配

- 0003：官方 0e6b441。增加 tx.in_flight 与 rate_sample.tx_in_flight；发送和 TCP_REPAIR 均采集快照。函数放在 tcp_output.c 且保持 static，因为两个调用都在同文件；诊断读取 cwnd 使用 tcp_snd_cwnd()。保留官方的 20 位上限告警与截断逻辑。
- 0004：官方 3679f3b。发送时记录 tp->lost，ACK 时记录 prior_lost，再计算整个采样区间的 rs.lost。保留现有 rs.losses（当前 ACK 新标记丢包）不变，不能混用两种统计。
- 0005：官方 500bcfe。仅透传 FLAG_ECE 为 rs.is_ece，保留 Ubuntu tcp_newly_delivered 的 ecn_count 参数。AccECN、低延迟 ECN 和后续 CE 回调尚未适配和验证。

五项串联精确应用已在固定 Ubuntu 提交的临时索引通过；verify_series.py 检查发送快照、repair 调用、丢包字段链路及 ECE 写入位置。源码断言不等同于运行时证明；整核编译和网络测试尚未执行。

## 第六至第八项适配

- 0006：官方 f207893，lost 计数递增之后调用可选 skb_marked_lost。Ubuntu tcp_congestion_ops 成员排列不同，将字段插入 min_tso_segs 后，不照搬旧邻接字段。
- 0007：官方 88e09e2，合并时转移 tx.in_flight；源 skb 计数不足时告警并归零。算法不改，沿用官方边界行为。
- 0008：官方 5093de5，分段时重新计算两个 skb 的在途快照；负的历史在途量归零，已标 lost 时避免因先前本地重传失败引发误报。Ubuntu flags 为 u16，保留不变，只调整补丁上下文。
- 八项串联精确检查通过。新增 test_inflight.py 从实际补丁提取 C 代码，用最小 skb 桩验证普通分段、lost 特例、异常下溢与合并转移；不能代替 packetdrill、内核编译或真实 RACK/RTO 路径测试。
- 待审阅边界：20 位 in_flight 的合并加法上溢可达性；当前忠实保留官方逻辑，不擅自引入饱和计算。后续补丁审查和测试需覆盖。

## 第九与第十项适配

- 0009：官方 6642024 的 WANTS_CE_EVENTS 原为 0x4，与 Ubuntu NEEDS_ACCECN 的 BIT(2) 冲突；改用空闲 BIT(5)，保留 Ubuntu 原有五个位及 MASK。只更改两个 CE 事件通知判断，保留 tcp_ecn_disabled 的提前返回与 RFC3168/AccECN 分支，未宣称完整 ECN 验收。
- 0010：官方 9163f44，改为 tso_segs 回调，包含 BPF 桩、BBR 调用和发送端选择逻辑。保留 Ubuntu 对 fallback sysctl 的 READ_ONCE；保留 bbr_min_tso_segs 辅助函数及已有 BTF kfunc 登记，因为它们不是旧 ops 成员。
- 十项精确应用通过，检查 CE 标志互不冲突及四个主要实现文件中的旧 TSO ops 引用消除。test_ce_flags.py 对补丁实际新增谓词测试全部 64 种标志组合。
- TSO 改动仍需全树调用方及 BPF selftests 审阅，随后通过整核编译、BTF 和实际分段行为测试；当前没有这些运行证据。

## 第十一至第十四项适配

- 0011：官方 4d2e564。Ubuntu 已将 recvmsg_inq 放入 tcp_sock_read_txrx 的 u8 位域组，使用剩余空间增加 fast_ack_mode，不按旧布局改成 u32。保留 init/disconnect 清零和官方 ACK 判断逻辑。
- 0012：官方 a631934。在 nonagle/rate_app_limited 的 u8 组增加一位，保留后面的 Ubuntu AccECN 字段。TLP 重传之前保存原始 skb 的 app-limited 状态。
- 0013：官方 3ee83ca。恢复事件在 cwnd reduction 之前通知，保留既有恢复步骤。
- 0014：官方 703f20a。两处 TLP ACK 入口均传递 rs，保留 Ubuntu 的 unlikely 分支及 tcp_in_ack_event 调用。匹配 TLP 序列不等于确定 ACK 来自重传，因此新位只代表歧义匹配，不可当作确定丢包。
- 十四项临时索引串联精确检查及新增初始化/状态链路检查通过。TLP 重传、重复 ACK、DSACK 和恢复事件仍需真实协议路径测试；尚未整核编译。

## 第十五项：低延迟 ECN 路由提示

- 官方来源 9120f8037e8b7a025e3998d1ec51b5e0fad837be。
- Google TCP_ECN_LOW 的原值 16 与 Ubuntu TCP_ECN_MODE_ACCECN 重叠，改用 BIT(5)，不改模式掩码；路由 UAPI 的 RTAX_FEATURE_ECN_LOW 仍使用原 BIT(5)，两个不同命名空间不可混淆。
- Ubuntu tcp_ecn_send_syn 已迁入 include/net/tcp_ecn.h。将路由提示设置放在现有 use_ecn 分支完成模式设置之后，保留 AccECN_PENDING 和 RFC3168 两种路径。
- 被动连接仍在 tcp_ca_openreq_child 中读取路由提示。未将“低延迟网络提示”当成“已成功协商 ECN”。
- 十五项串联精确应用通过，并检查两个初始化点与 AccECN 模式位保留。连接建立后的回退、模式切换及所有 ecn_flags 清零路径仍须与主算法整体复核，不代表 ECN 网络行为通过。

## 第十六项：主算法候选

- 来源 cb31f3d02b1d7cd7cfdff4dd2b8b9d38879904af，包含主算法、私有状态空间、PLB 布局和诊断信息。
- 旧算法删除上下文适配 Ubuntu 的 WRITE_ONCE 修改。新增代码的共享字段读写仍需完整审查。
- bbr_can_use_ecn 使用 tcp_ecn_mode_rfc3168() 和 LOW 提示，保守排除尚未验证的 AccECN/协商中状态；这是本项目的适配选择，不是 Google 官方 Ubuntu 支持声明。
- 十六项串联精确应用通过。新增手动专用 targeted compile 工作流，仅实验分支可运行，只编译相关 IPv4 对象，不发布包。
- defconfig 对象编译不能替代 Ubuntu 全配置、BPF/BTF、IPv6、整包安装、启动及网络测试。后续重传 ECN 和 tcp_info 补丁仍待完成。
