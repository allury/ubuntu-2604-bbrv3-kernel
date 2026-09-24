# 项目结构与维护

## 目录职责

| 路径 | 用途 |
| --- | --- |
| `.github/workflows/build-kernel.yml` | 官方源解析、完整内核构建、安装与启动验收、发布 |
| `.github/workflows/installer-check.yml` | 独立安装器检查，不编译内核 |
| `.github/workflows/installer-release.yml` | 推送 `installer-v*` 标签后，待该提交的安装器检查和虚拟机验收通过，按更新记录创建安装器 Release，不设为 Latest |
| `.github/workflows/repo-checks.yml` | 修改脚本、测试、补丁或工作流时运行，不编译内核：ShellCheck、工作流解析、补丁批准哈希、脚本行为测试、对当前 Ubuntu 发布源的补丁应用与变化报告，以及用最新正式内核执行 QEMU 冒烟 |
| `.github/workflows/vm-acceptance.yml` | 修改安装器或虚拟机测试时运行：用安装器的安装逻辑把最新正式内核装进 Ubuntu 26.04 云镜像虚拟机，分别验证试启动通过后成为默认，以及试启动崩溃后自动回到原内核。发布流程在发布新内核前运行前一个场景 |
| `installer/install.sh` | 用户安装入口，按独立版本标签发布 |
| `scripts/` | 构建、校验、恢复工具及内核 Release 随附的基线安装脚本 |
| `config/` | 内核附件的基线配置；独立安装器内嵌自己的配置 |
| `patches/` | 固定补丁与移植策略 |
| `tests/` | 源版本解析、安装器分支、ZFS 预检、QEMU、云镜像虚拟机安装重启和外部模块测试 |
| `docs/` | 项目维护和构建恢复说明 |

根目录仅保留项目介绍和仓库配置。临时构建目录、下载包、签名密钥、日志和本地工作记录不应提交。

## 历史基线与当前安装器

- 内核版本：`7.0.0-13002-generic`，正式版标签 `ubuntu-26.04-bbrv3-7.0.0-30.30-p2`。
- 构建逻辑基线：`db2c4b0`。
- [正式版完整验收记录](https://github.com/allury/ubuntu-2604-bbrv3-kernel/actions/runs/33967676484)：构建、真实包安装、外部模块编译、QEMU 内核启动、BBRv3 TCP 传输及 ZFS 加载。
- [安装器 v1.1.0 验收记录](https://github.com/allury/ubuntu-2604-bbrv3-kernel/actions/runs/34460015729)：静态检查、参数传递、回退保护、引导文件检查、磁盘预算和解析器测试。
- 安装器 v1.2.0 验收记录（安装逻辑提交 `a2e40eb`）：[安装器检查](https://github.com/allury/ubuntu-2604-bbrv3-kernel/actions/runs/35980795982)，覆盖以上各项及试启动参数、菜单项解析、前提条件判断；[虚拟机验收](https://github.com/allury/ubuntu-2604-bbrv3-kernel/actions/runs/35980796103)，覆盖试启动通过后成为默认，以及试启动崩溃后自动回到原内核。
- 上述内核是历史基线，不是最新版本声明。最新正式内核见 [发布页](https://github.com/allury/ubuntu-2604-bbrv3-kernel/releases/latest)，安装器变更见 [更新记录](../installer/CHANGELOG.md)。

安装器分支测试不等于在所有 VPS 上完成安装与重启验证。虚拟机验收只覆盖 BIOS 引导的 Ubuntu 26.04 云镜像；它和 QEMU 冒烟都不保证所有硬件、服务商引导配置和第三方模块均兼容。

## 安装器更新

1. 修改独立入口及对应测试，不为安装器改动重编译内核。
2. 通过安装器 CI 与虚拟机验收（修改 `installer/` 时自动运行），其中试启动崩溃后自动回到原内核的场景必须通过。虚拟机验收不能代替真实 VPS；v1.1.0 和 v1.2.0 目前都没有真实 VPS 的重启验收记录。
   修改试启动逻辑时，须保持以下行为：GRUB 无法清除一次性启动项的环境不做试启动；失败的试启动不留下待执行的启动项；只有开机验收可以把新内核设为默认启动项。
3. 在 `installer/install.sh` 首行注释和 `installer/CHANGELOG.md` 中写明新版本号，并把 README 的两种安装命令改为引用同一新标签。
4. 在同一次推送中把 `main` 和新的 `installer-vX.Y.Z` 标签推送到同一提交（`git push --atomic`），避免 README 引用尚不存在的标签；不移动已有标签。
5. 标签推送后，`installer-release.yml` 会等该提交的安装器检查和虚拟机验收通过，再用更新记录中该版本的条目创建中文 Release，并且不设为 Latest，以免干扰 `/releases/latest` 选择正式内核。已存在的 Release 不会被修改，旧标签和内核附件也不会被改动。

内核 Release 随附的历史脚本与独立入口用途不同，不应删除或将它们混用。已发布附件保留原样；修订内核包应发布新版本，而不是覆盖附件。

## 内核更新

定时任务只负责检查、编译、验收和发布；不会修改服务器。补丁无法精确应用时需要人工适配，不以绕过测试来完成发布。

补丁只有在维护者审核后，才能在同一提交中把 SHA-256 写入 `patches/APPROVED-SHA256SUMS`；构建拒绝未列入清单的补丁。每个 Release 附带的 `PATCH-BASELINE-DRIFT.txt` 列出补丁涉及文件相对审核基线的 Ubuntu 改动，有变化时应审阅，详见 [补丁策略](../patches/README.md)。

恢复流程见 [构建恢复](BUILD-RECOVERY.md)，补丁维护见 [补丁策略](../patches/README.md)。检查点必须尚未过期，且源码、补丁和核心打包输入保持一致。

当前恢复的稳定构建工作流未显式设置 `retention-days`，制品有效期由仓库或组织设置决定，不能假定为一天。制品过期后不能依靠该检查点续建。

## 发布边界

文本使用 UTF-8、LF 和末尾换行，遵循 `.editorconfig` 与 `.gitattributes`。不得批量清除补丁上下文空格。用户说明使用中文，命令、文件名和技术日志保留原始标识。

稳定版继续使用第三方补丁；Google 独立移植实验暂停，不并入当前发布。已实现和待补检查见 [补丁策略](../patches/README.md)。

本项目是第三方定制内核，不是 Canonical 官方内核或安全支持服务。校验和不代替发布者身份认证，稳定版标签也不代表 GitHub 已强制锁定附件。

保留上游补丁和源码的版权及许可证声明；不擅自给上游内核或第三方补丁重新授权。
