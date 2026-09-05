# Ubuntu 26.04 BBRv3 Kernel

为 Ubuntu 26.04（amd64）构建的内置 BBRv3 TCP 拥塞控制的完整 generic 内核。项目直接采用 Canonical 已发布的 Ubuntu 26.04 内核源码与配置，在源码层合入 BBRv3 修改，完整构建内核映像、全部模块、headers 以及与自定义 ABI 匹配的 OpenZFS 模块包，而非在原装内核上单独替换 `tcp_bbr.ko`。每个版本发布前均通过干净系统安装验证与 QEMU 启动测试（BBRv3、OpenZFS 加载及 TCP 传输）。

- 当前版本：`ubuntu-26.04-bbrv3-7.0.0-30.30-p2`（内核 `7.0.0-13002-generic`）
- 发布地址：<https://github.com/allury/ubuntu-2604-bbrv3-kernel/releases/latest>
- 自定义 ABI 与官方内核并存，可随时经 GRUB 回退，不影响 `apt` 对原装内核的更新

## 安装

适用于 Ubuntu 26.04 amd64 环境（物理机或全虚拟化 VPS，systemd 与 GRUB）。

```bash
curl -fsSLO https://github.com/allury/ubuntu-2604-bbrv3-kernel/releases/latest/download/download-and-install.sh
less download-and-install.sh
sudo bash download-and-install.sh --reboot
```

安装脚本仅接受稳定 Release（拒绝 draft 与 prerelease），下载该 Release 全部资产并校验 `SHA256SUMS`，检查包白名单与依赖闭包后执行安装；保留原装内核并更新 GRUB，`--reboot` 参数控制是否自动重启。脚本不使用 `--force-depends`，任一步骤失败即终止。

安装前置条件（脚本自检，不满足将拒绝执行）：

- 系统中至少保留一个可启动的 Canonical 原装 generic 内核作为回退，缺失时可通过 `sudo apt-get install linux-image-generic` 补装；
- dpkg 状态健康，`sudo dpkg --audit` 输出为空。

重启完成后验证运行状态：

```bash
uname -r                              # 7.0.0-13002-generic
cat /sys/module/tcp_bbr/version       # 3
journalctl -u bbrv3-verify -b --no-pager
```

回退方式为在 GRUB 菜单选择原装内核启动，无需卸载。

### 自历史版本升级

已安装 `p1`（`7.0.0-10030-generic`）的环境可直接安装新版本：两者使用不同自定义 ABI，包名互不冲突，安装器仅要求当前运行内核与目标内核不同。既有 `p1` 包及临时占位 OpenZFS 包在升级期间保留，作为回退手段。新版本安装并通过运行验收后，可移除历史版本：

```bash
sudo apt-get purge 'linux-*-7.0.0-10030-generic'
```

## 源码来源

| 组件 | 来源 | 说明 |
|---|---|---|
| 内核源码 | [Ubuntu 内核团队 resolute 仓库](https://git.launchpad.net/~ubuntu-kernel/ubuntu/+source/linux/+git/resolute) | 克隆精确发布 tag（如 `Ubuntu-7.0.0-30.30`）；版本取自 `resolute`、`resolute-updates`、`resolute-security` 的已签名 APT 元数据，排除 `proposed`、`backports` 与 PPA |
| BBRv3 实现 | [Google BBR v3](https://github.com/google/bbr/tree/v3) | 算法实现基线 |
| Linux 7.0 移植补丁 | [byJoey/Actions-bbr-v3](https://github.com/byJoey/Actions-bbr-v3) 提交 `d6bd606b` | 非 Google 官方 Ubuntu 补丁；以 SHA-256 锁定，须通过精确 `git apply --check --whitespace=error`；经等同性审计与 Google 官方实现一致（见 [`docs/PATCH-AUDIT.md`](docs/PATCH-AUDIT.md)） |
| OpenZFS 模块 | Ubuntu 26.04 官方 `zfs-dkms` 同版本源码 | 针对自定义 ABI 重新编译并以本内核密钥签名 |
| 构建环境 | GitHub Actions | 所用 action 固定至核对过的 commit SHA；产物附 `SHA256SUMS`、构建元数据与包清单 |

本项目沿用 Ubuntu 26.04 已发布源码、配置与包关系，不属于 Canonical 官方产品，未经 Canonical 签名，不包含 Canonical 支持。

## 版本记录

| 版本 | 内核 | 状态 |
|---|---|---|
| `p2` | `7.0.0-13002-generic` | 当前正式版本，通过全部发布门禁 |
| `p1` | `7.0.0-10030-generic` | 历史预发布版本，Release 缺少 `linux-main-modules-zfs-*` 依赖包，仅作存档 |

`p1` 已在实际 Ubuntu 26.04.1 环境中验证 BBRv3 运行（`/sys/module/tcp_bbr/version` 为 `3`，`ss -ti` 输出包含 `bbr` 参数），但因依赖包缺失需占位包绕过，由 `p2` 取代。

## 发布门禁

每个正式版本须依次通过以下验证，任一失败即不发布：

1. 构建完整 Ubuntu generic 内核映像、模块与 headers；
2. 保留 `linux-modules-$release` 对 `linux-main-modules-zfs-$release` 的依赖关系；
3. 从 Ubuntu `zfs-dkms` 构建 `spl.ko` 与 `zfs.ko`，以该内核构建密钥签名，生成 ABI 精确匹配的 `.deb`；
4. 校验全部包名、版本、架构、依赖与 Provides、SHA-256、模块路径、签名、BBRv3 `version=3` 及各模块 vermagic；
5. 在干净 Ubuntu 26.04 容器中先执行 `apt-get --simulate --no-remove install`，再真实安装全部 `.deb`，`dpkg --audit` 输出须为空；
6. 使用产物中的精确 `vmlinuz` 于 QEMU 启动，实际加载 `tcp_bbr`、`spl`、`zfs`，建立选用 `bbr` 的 TCP 连接并完成数据传输；
7. 全部通过后创建正式 GitHub Release。

## 自动更新

定时任务每天 02:23 UTC 检查 Ubuntu 26.04 已发布的 `linux-image-generic` 候选版本：

- 已存在同源版本与补丁修订的 Release 时跳过；
- 出现新版本时完整重建并重复全部发布门禁；
- TCP 栈变更导致补丁无法精确应用时停止发布并创建 porting issue。

工作流支持手动触发，输入可为 `auto` 或精确源版本号。本仓库仅负责构建与发布，不执行服务器端自动安装或重启。

## Secure Boot

内核模块以构建时生成并嵌入内核的密钥签名；镜像为 `linux-image-unsigned-*`，未经 Canonical 签名。启用 Secure Boot 的主机须完成自定义镜像签名与信任注册，或在确认风险后关闭 Secure Boot，安装器在条件不满足时终止。

## 补丁策略

补丁须通过精确 `git apply --check --whitespace=error` 后方可进入构建，不使用 `patch -f`、三路模糊合并或单模块回退方案。新的内核系列不兼容时执行人工移植并提升 `patch_revision`，生成新的不可变 Release 标签。详见 [`patches/README.md`](patches/README.md)。
