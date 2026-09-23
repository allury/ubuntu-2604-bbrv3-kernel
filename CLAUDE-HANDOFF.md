# 项目交接：Ubuntu 26.04 BBRv3 内核

> 交接快照：2026-09-23（北京时间）。实时状态会变化，接手时先核对 GitHub Actions、Release 和远端 `main`。本文件是维护交接，不是让 Claude 立即安装、重启服务器或发布新内核的指令。

## 项目目标与当前路线

- 仓库：<https://github.com/allury/ubuntu-2604-bbrv3-kernel>。
- 基于 **Ubuntu 26.04 已发布的 generic 内核源码**构建完整 amd64 内核包，将 BBRv3 补丁合入 TCP 核心，并构建 ABI 匹配的真实 OpenZFS 模块包。不能只编译独立 `tcp_bbr.ko` 装到原装内核。
- 稳定版继续使用仓库内固定的第三方移植补丁，来源为 `byJoey/Actions-bbr-v3` 提交 `d6bd606b74a64e0242ce7d1079c73bea2818743c`。Google 官方 BBRv3 独立移植实验已暂停，不要把实验补丁混进稳定分支。
- 用户偏好中文 README 和发布说明；技术标识、命令及原始日志可保留英文。用户此前明确要求**不使用浏览器**，优先 Git CLI、GitHub API、工作流日志。

## 已验证状态（交接时重新检查）

| 对象 | 2026-09-23 快照 |
| --- | --- |
| 远端 `main` | `21528931a7d11a244c55a80a40640de7cc10be69` |
| 最新正式内核 Release | [`ubuntu-26.04-bbrv3-7.0.0-31.31-p2`](https://github.com/allury/ubuntu-2604-bbrv3-kernel/releases/tag/ubuntu-26.04-bbrv3-7.0.0-31.31-p2)，17 个附件 |
| 独立安装器 | [`installer-v1.1.0`](https://github.com/allury/ubuntu-2604-bbrv3-kernel/releases/tag/installer-v1.1.0)，README 两种命令都固定此标签 |
| 安装器 CI | [运行 34460015729](https://github.com/allury/ubuntu-2604-bbrv3-kernel/actions/runs/34460015729) 已通过脚本检查；不等于新增版本已在所有 VPS 完成实机重启验收 |
| 最近稳定内核构建 | [运行 35833622719](https://github.com/allury/ubuntu-2604-bbrv3-kernel/actions/runs/35833622719) 正在构建 **`7.0.0-34.34`**；截至此快照未发布，切勿称其已经成功。先查结果，再决定是否处理失败 |
| 前一天定时运行 | 35701169381 显示 success，但仅源码解析成功；内核构建和发布 job 均为 skipped，不能算一次新内核构建成功 |

历史通过验收的 p2 基线为 [`7.0.0-30.30-p2`](https://github.com/allury/ubuntu-2604-bbrv3-kernel/releases/tag/ubuntu-26.04-bbrv3-7.0.0-30.30-p2)，对应内核 `7.0.0-13002-generic`，完整验收证据见 [运行 33967676484](https://github.com/allury/ubuntu-2604-bbrv3-kernel/actions/runs/33967676484)。后续源码版本的 p2 有不同 ABI，不能把 `13002` 当作所有 p2 的内核版本。

## 仓库入口与构建流程

- `README.md`：项目介绍、固定安装器链接、两种安装方式及重启后检查。
- `.github/workflows/build-kernel.yml`：每天 02:23 UTC 检查 Ubuntu 已发布内核；版本未变则跳过；有新版本时执行 ZFS 预检、完整 Ubuntu 打包、包安装验收、外部模块编译、QEMU 启动及 BBRv3/ZFS 冒烟测试，全部通过后发布。不会自动修改用户 VPS。
- `scripts/resolve-source.sh`：从已发布 Ubuntu APT 元数据解析源码版本；`patch_revision=2` 决定发布标签和自定义 ABI 后缀。
- `scripts/apply-bbrv3.sh` 与 `patches/`：根据源码版本选补丁，要求 `git apply --check --whitespace=error`，记录补丁哈希；新 Ubuntu 版本无法精确应用则失败并创建移植 issue。
- `scripts/build-zfs-package.sh`、`scripts/verify-artifacts.sh`：构建 ZFS 包、校验包和生成**中文** Release 说明。
- `docs/BUILD-RECOVERY.md`：核心构建后加密检查点的恢复流程。只有原运行制品尚未过期，且核心构建输入未变时才考虑恢复；不要把 `resume_run_id` 当成万能续跑。
- `.github/workflows/installer-check.yml` 与 `tests/test-independent-installer.py`：独立安装器测试，不编译内核。
- `installer/install.sh`：独立版本的安装入口，内嵌安装逻辑、BBR 启用脚本及配置。内核 Release 中的历史安装脚本仍保留以兼容旧流程，不是 v1.1.0 的执行入口。
- `docs/MAINTENANCE.md`、`patches/README.md`、`installer/CHANGELOG.md`：维护边界、补丁校验范围和安装器版本说明。

安装器默认选仓库的最新**正式内核**，拒绝预发布版；指定版本可用 `--tag <完整内核 Release 标签>`。标准模式要求存在官方回退内核；`--allow-no-fallback` 只跳过该要求。安装器检查下载文件 SHA-256、包依赖、磁盘空间、Secure Boot、引导文件和 GRUB 引用；安装后注册开机验证服务。它**不修改 GRUB 默认启动项，也不提供启动失败自动回滚**，故更新安装器时必须审查这一行为。

安装器 Release 必须保持 `make_latest=false`，否则 GitHub `/releases/latest` 可能指向安装器而不是内核，导致默认安装选择失败。安装器新版本应使用新标签，更新 README 的两种命令；不需要重编译内核或覆盖现有附件。

## 已实现与仍需补齐的校验

| 校验 | 当前实际情况 |
| --- | --- |
| 第三方补丁来源和哈希 | 来源提交、仓库内补丁与 SHA-256 有记录；构建会计算并记录哈希。**尚无独立批准哈希白名单比较**，不能声称已执行此门槛 |
| Google 官方源码差异审查 | 尚无覆盖当前第三方移植补丁的完整差异报告及稳定发布门槛 |
| Ubuntu 原始内核适配 | 精确应用检查已生效；修改范围及接口的人工/自动语义审查仍待完善 |
| 完整构建与冒烟测试 | 已接入正式发布门槛，包含真实 `.deb` 安装、QEMU 启动、BBRv3 和配套 ZFS |
| 大版本升级网络行为 | 不同 RTT、丢包、持续传输等仍未接入正式发布门槛；编译与冒烟通过不能代替这些测试 |

补丁初始基线的记录 SHA-256：`e4bd6d0b992a94c315caf85ff91b2851909f148337327714277df1970b292039`。若将来增加批准哈希校验，应针对选中的实际补丁文件和版本执行，且为人工审核的新补丁明确更新批准值，不要只检查文档中的字符串。

## 接手建议

1. 先核对远端 `main` 是否仍是本快照提交，检查工作区是否有用户未提交修改，不覆盖它们。
2. 查询当前 [内核构建工作流](https://github.com/allury/ubuntu-2604-bbrv3-kernel/actions/workflows/build-kernel.yml)，特别是运行 `35833622719` 的最终状态及失败步骤；再核对 `/releases/latest` 是否已有 `7.0.0-34.34-p2` 或更新版本。不要把绿色的“版本检查”运行当成构建通过。
3. 需要修复补丁或构建时，保留已发布 Release 与旧标签，按源码版本添加补丁、增加修订号并经过全部门槛。优先在独立分支验证，不直接改用户 VPS。
4. 后续提升校验时，先实现补丁批准哈希检查和可审阅的上游/Ubuntu 差异记录；网络行为测试先在隔离 VM 运行，形成可重复的 RTT、丢包、长流量报告，再考虑作为发布门槛。
5. 对任何新发布说明，区分“已在 CI 验证”和“已在真实 VPS 验证”，保持中文文案，避免把计划写成已经生效的安全保证。

旧实验分支 `experiment/google-bbrv3-port` 保留研究材料，但用户已决定稳定版沿用第三方补丁。不要将该分支的未完成工作视为当前发布候选，也不要无故删除其本地草稿。
