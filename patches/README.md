# BBRv3 补丁策略

`bbrv3-ubuntu-7.0.0-30.30.patch` 是完整 TCP 栈移植补丁，不是一个可在发行版原装内核上单独加载的 `tcp_bbr.ko`。它同时修改 TCP 核心和 BBR 实现。

初始补丁已经规范为 LF 换行，并在精确源码 tag 上验证：

```text
Ubuntu source tag: Ubuntu-7.0.0-30.30
git apply --check --whitespace=error
SHA-256: e4bd6d0b992a94c315caf85ff91b2851909f148337327714277df1970b292039
```

Linux 7.0 移植基线来自 [`byJoey/Actions-bbr-v3`](https://github.com/byJoey/Actions-bbr-v3) 的提交 `d6bd606b74a64e0242ce7d1079c73bea2818743c`，并以官方 [Google BBR v3](https://github.com/google/bbr/tree/v3) 实现为依据。它不是 Google 对 Ubuntu 26.04 的官方发布包。

工作流允许将此基线补丁用于后续的 Ubuntu 源码版本，前提是它先通过**精确** `git apply --check --whitespace=error`，再通过完整编译和 artifact 验证。它不会使用 `patch -f`、三路模糊合并或只编译单模块的回退方案。

若新的 Ubuntu 版本无法精确应用该补丁，CI 会停止发布并创建 porting issue。完成真实移植后，应新增 `bbrv3-ubuntu-<source-version>.patch`，验证后提高 `scripts/resolve-source.sh` 里的 `patch_revision`，生成新的 Release 标签，不覆盖已有版本。这是项目发布约定，不代表 GitHub 已启用不可变发布锁定。

## 当前检查范围

| 检查 | 实施状态 |
| --- | --- |
| 补丁来源记录与仓库内保存 | 已有；构建不在线追随第三方最新补丁 |
| 批准哈希比对 | 待实现；目前计算并记录 SHA-256，不与独立批准值比对 |
| 精确应用 | 已有；允许行号偏移，不使用模糊匹配或三路合并 |
| 对照 Google 官方源码的完整移植差异审查 | 待补报告与发布准入条件 |
| Ubuntu 接口与语义兼容性审查 | 不能仅靠精确应用证明，仍需审查 |
| 完整编译、安装、外部模块、QEMU 启动及 BBRv3/ZFS 冒烟测试 | 已接入正式发布流程 |
| 较大内核升级的 RTT、丢包及持续传输测试 | 尚未接入正式发布流程 |

继续维护第三方补丁路线；Google 独立移植实验暂停。待办不是已生效的安全保证，不能仅凭编译成功宣称所有网络场景正常。
