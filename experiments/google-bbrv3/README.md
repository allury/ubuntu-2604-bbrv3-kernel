# Google 官方 BBRv3 移植实验

状态：来源核对与差异提取阶段，尚无可发布的自维护移植补丁。

本实验只在 `experiment/google-bbrv3-port` 分支推进。不修改 main 的补丁选择逻辑、定时发布配置或现有 p2 附件；不自动发布实验内核。

## 固定来源

| 对象 | 仓库 | 提交 |
| --- | --- | --- |
| Google BBRv3 | https://github.com/google/bbr.git | `90210de4b779d40496dee0b89081780eeddf2a60` |
| Google 分支的 Linux 6.13.7 基线 | 同一仓库的祖先提交 | `648e04a805652f513af04b47035cde896addf9b0` |
| Ubuntu 7.0.0-30.30 | https://git.launchpad.net/~ubuntu-kernel/ubuntu/+source/linux/+git/resolute | `d974a4063f5c03c13b4f241a9ab511750e0b9f12` |

2026-09-06 通过 Google 远端 `refs/heads/v3` 核对提交；本地 merge-base 确认上述 Linux 基线是其祖先。完整分支差异涉及 31 个文件，包含内核、测试、GCE 配置和 iproute2 补丁，不能将整个差异不加区分地作为 Ubuntu 内核补丁。

## 重现初始检查

准备包含以上提交对象的 Google 与干净 Ubuntu Git 仓库，Ubuntu HEAD 必须为上述固定提交。执行：

```bash
python3 experiments/google-bbrv3/inspect.py --google /path/to/google-bbr --ubuntu /path/to/ubuntu-linux --output /tmp/bbrv3-inspect-new
```

脚本不会联网、修改源码、应用补丁或编译。它记录固定提交、提交序列、所有文件差异，导出 include/ 与 net/ 下的官方原始差异，并对与固定提交一致的 Ubuntu Git 索引执行精确应用检查，避免 Windows 大小写冲突文件干扰；不检查工作区修改。原始差异包含 BBRv1 对照测试相关改动，尚不是最终生产补丁。

检查失败是待移植证据，不代表可采用模糊应用绕过；检查成功也不代表语义正确。输出目录必须不存在，避免覆盖已有研究结果。

## 移植与验收顺序

1. 将官方提交分为核心算法、TCP 采样与拥塞控制接口、ECN/UAPI、对照测试和外部工具，逐项记录纳入或排除理由。
2. 对照 Ubuntu 7.0 的已有实现，逐项适配；每个非机械修改记录原因、官方来源和影响。
3. 形成自维护补丁并独立审查。现有第三方补丁仅作差异审阅参考，不作为生成输入。
4. 精确应用、配置校验、完整编译、真实包安装、headers 测试和 QEMU BBRv3/ZFS 测试。
5. 在隔离环境覆盖不同 RTT、丢包、ECN、持续传输以及与稳定 p2 的对照，保留参数与日志；不预设必须更快。
6. 人工审阅验收证据后再决定是否用于下一版，明确批准前不合并到 main。

保留所有上游版权和许可证信息。官方算法来源不等于官方认可 Ubuntu 移植。

## 第一版网络测量工具

`network_matrix.py` 已实现 IPv4 发送端的三个初始场景：20 ms 无丢包、100 ms 无丢包、100 ms/1% 丢包，均为 100 Mbps 瓶颈，默认每项 30 秒、重复 5 次。RTT 配置为路由器两个方向各一半延迟，随机丢包仅施加于数据方向。

```bash
# 只打印计划，不创建命名空间
python3 experiments/google-bbrv3/network_matrix.py

# 仅在可销毁的 Linux VM 中执行；替换为实际实验内核版本
sudo python3 experiments/google-bbrv3/network_matrix.py --execute \
  --expected-kernel '<实验内核版本>' --output /var/tmp/bbr-matrix-new
```

所需工具：iproute2、iperf3、iputils-ping、ethtool、kmod、procps、util-linux 和 systemd-detect-virt。执行不会操作宿主机物理接口，但仍应只用专用测试 VM，且会加载其 tcp_bbr 模块。每次只清理本次创建的命名空间，输出目录不得已存在。

输出包括环境信息、脚本哈希、ping、iperf3 JSON、tc 统计及前后内核日志。目前 CI 只验证语法、参数与结果解析；尚未在目标 VM 真实跑通，不能当作行为验收通过。IPv6、ECN、动态网络、多流竞争、内容哈希验证、实时 ss 采样和基线统计比较仍按 [验证清单](VALIDATION.md) 待补；工具不会自动宣告稳定。

移植进展见 [移植记录](PORT-NOTES.md)。

已实现的前置补丁按 `patches/series` 顺序维护。只验证临时索引、不修改工作区：

```bash
python3 experiments/google-bbrv3/verify_series.py --ubuntu /path/to/ubuntu-linux
```

当前含十五项前置改动及主算法候选补丁（0016），仍在接口验证阶段，禁止用于生产构建。
