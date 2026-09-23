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

若新的 Ubuntu 版本无法精确应用该补丁，CI 会停止发布并创建 porting issue。完成真实移植后，应新增 `bbrv3-ubuntu-<source-version>.patch`，并在同一提交中把审核后的 SHA-256 写入 `APPROVED-SHA256SUMS`；验证后提高 `scripts/resolve-source.sh` 里的 `patch_revision`，生成新的 Release 标签，不覆盖已有版本。这是项目发布约定，不代表 GitHub 已启用不可变发布锁定。

## 批准哈希

`APPROVED-SHA256SUMS` 使用 `sha256sum` 格式，每个允许构建使用的补丁文件占一行，由维护者审核补丁后写入。构建在应用补丁前核对所选补丁文件的实际 SHA-256；清单缺失、没有对应条目、条目重复或哈希不一致都会使构建失败。这类失败属于仓库问题，不会创建 porting issue。生成发布说明前，还会再次核对随 Release 附带的补丁文件。仓库检查工作流在补丁变更时运行 `sha256sum --check --strict APPROVED-SHA256SUMS`。

清单只能随经过审核的补丁一起更新，不能为了让构建通过而单独修改。

## 基线变化报告

补丁文件名中的 Ubuntu 版本就是它的审核基线，例如 `bbrv3-ubuntu-7.0.0-30.30.patch` 的基线是 `Ubuntu-7.0.0-30.30`。每次构建都会比较补丁涉及的文件在审核基线与本次源码之间的差异，写入 Release 附件 `PATCH-BASELINE-DRIFT.txt`，并在发布说明中注明变化的文件数和行数。

补丁能精确应用只说明上下文行没有变化，这些文件其他位置的 Ubuntu 改动仍可能影响 BBRv3。按维护者决定，报告只供审阅：不阻止发布，也不把有变化的版本改为预发布版。

## 当前检查范围

| 检查 | 实施状态 |
| --- | --- |
| 补丁来源记录与仓库内保存 | 已有；构建不在线追随第三方最新补丁 |
| 批准哈希比对 | 已有；构建前核对 `APPROVED-SHA256SUMS`，生成发布说明前再次核对随附补丁 |
| 精确应用 | 已有；允许行号偏移，不使用模糊匹配或三路合并 |
| 补丁涉及文件相对审核基线的变化 | 已有报告 `PATCH-BASELINE-DRIFT.txt`；按维护者决定不作为发布门槛，变化需人工审阅 |
| 对照 Google 官方源码的完整移植差异审查 | 待补报告与发布准入条件 |
| Ubuntu 接口与语义兼容性审查 | 不能仅靠精确应用或变化报告证明，仍需审查 |
| 完整编译、安装、外部模块、QEMU 启动及 BBRv3/ZFS 冒烟测试 | 已接入正式发布流程；QEMU 中完成 32 MiB 回环传输并校验内容，通过 `TCP_CC_INFO` 确认连接上报 BBR 版本 3 和非零带宽估计；传输期间出现内核警告、oops 或新的 B/D/W/L taint 标志即失败 |
| 云镜像虚拟机中的安装与重启验收 | 已接入正式发布流程；用安装器的安装逻辑在 BIOS 引导的 Ubuntu 26.04 云镜像虚拟机中安装，经 GRUB 默认启动项和新生成的 initramfs 重启进入新内核，并通过安装器的开机验收 |
| 较大内核升级的 RTT、丢包及持续传输测试 | 尚未接入正式发布流程 |

继续维护第三方补丁路线；Google 独立移植实验暂停。待办不是已生效的安全保证，不能仅凭编译成功宣称所有网络场景正常。
