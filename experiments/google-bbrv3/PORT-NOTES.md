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
