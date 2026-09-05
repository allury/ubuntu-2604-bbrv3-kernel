# Ubuntu 26.04 BBRv3 kernel

本仓库从 Ubuntu 26.04 已发布的 `linux` 源码和配置构建完整的 amd64 generic 内核，在源码层合入 BBRv3 对 TCP 栈的完整修改。产物包含 `vmlinuz`、全部内核模块、headers、buildinfo，以及与自定义 ABI 匹配的真实 OpenZFS 模块包；不是给 Canonical 原装内核单独替换一个 `tcp_bbr.ko`。

## 当前状态

历史 `p1` 构建产生了 `7.0.0-10030-generic`。用户已在 Ubuntu 26.04.1 VPS 上实际启动该内核，并取得以下运行证据：

- `uname -r` 为 `7.0.0-10030-generic`；
- `/sys/module/tcp_bbr/version` 为 `3`；
- 真实 HTTPS TCP 连接的 `ss -ti` 输出包含 `bbr:(bw:..., pacing_gain:..., cwnd_gain:...)`。

这证明该版完整内核中的 BBRv3 能启动和处理真实 TCP 流量。但 `p1` 的 `linux-modules-*` 依赖匹配 ABI 的 `linux-main-modules-zfs-*`，Release 却没有提供该包；用户只能用临时占位包绕过。因此 `p1` 仅保留为历史 prerelease，不应再用于新安装，也不得把占位包方案带到后续版本。

`p2` 使用新的自定义 ABI，并恢复 Ubuntu 26.04 的完整包关系。它只有在干净系统安装、QEMU 启动、BBRv3 和 OpenZFS 加载测试全部通过后才发布为正式 Release。

## 来源与安全边界

- 自动解析只接受 Ubuntu 26.04 的 `resolute`、`resolute-updates` 和 `resolute-security`；拒绝 `proposed`、`backports`、PPA 和其他发行版。
- 从 `linux-image-generic` 的已发布 APT 元数据解析版本，再交叉核对匹配的 `linux-image-unsigned-*` 确实来自 `linux` 源包。
- 克隆精确 Launchpad tag（例如 `Ubuntu-7.0.0-30.30`），并核对 `debian.master/changelog` 与请求版本一致。
- BBRv3 补丁先通过精确 `git apply --check --whitespace=error`；不会模糊合并。未来内核不兼容时停止发布并创建移植 issue。
- OpenZFS 只取同一 Ubuntu 26.04 APT 环境中的 `zfs-dkms` 候选版本，记录源版本和下载包 SHA-256，并针对自定义 headers 重新编译。
- GitHub Actions 均固定到已核对的 commit SHA，凭据不写入 checkout；构建步骤不持有 Release 写权限令牌。

“对齐 Ubuntu 26.04”表示沿用其已发布源码、配置和包关系，不表示这是 Canonical 官方或 Canonical 签名内核。

## 每个正式版的自动门禁

1. 构建完整 Ubuntu generic 内核映像、模块和 headers。
2. 保留 `linux-modules-$release` 对 `linux-main-modules-zfs-$release` 的依赖。
3. 从 Ubuntu `zfs-dkms` 构建 `spl.ko` 与 `zfs.ko`，使用该内核的构建密钥签名，并生成同名匹配 ABI 的 `.deb`。
4. 校验所有包名、版本、架构、依赖/Provides、SHA-256、模块路径、签名、BBRv3 `version=3` 以及所有模块的精确 vermagic。
5. 在干净 Ubuntu 26.04 容器中先执行 `apt-get --simulate --no-remove install`，再真实安装全部 `.deb`，且 `dpkg --audit` 必须为空。
6. 使用产物中的精确 `vmlinuz` 在 QEMU 启动，实际加载 `tcp_bbr`、`spl`、`zfs`，创建选择 `bbr` 的 TCP 连接并传输数据。
7. 全部成功才创建正式 GitHub Release；任一失败都不发布。

ZFS 门禁会在后续每个内核 ABI 上自动重复，因为“包被带入”不能证明外部模块仍与新内核接口兼容。

## 构建与自动跟随 Ubuntu 更新

Actions 的手动输入默认是 `auto`。也可输入仍存在于 Ubuntu 26.04 已发布仓库中的精确源版本，例如 `7.0.0-30.30`。定时任务每天 02:23 UTC 检查 `linux-image-generic` 当前候选版本：

- 已有同一源版本和补丁修订的 Release：跳过；
- 新版本且补丁、编译和全部门禁成功：发布新的正式版；
- TCP 栈变化导致补丁不再精确适用：停止并创建 porting issue，不发布二进制包。

这只自动构建和发布，不会自动登录服务器、安装内核或重启 VPS。

## 一键下载、安装、重启和启动后测试

正式版安装器要求 Ubuntu 26.04 amd64、systemd、GRUB、正常的 dpkg 状态，以及至少一个可启动的 Canonical 原装 generic 内核作为回退。你当前机器的 `/boot` 输出只显示一个自定义内核，因此应先恢复原装回退内核：

```bash
sudo apt-get update
sudo apt-get install linux-image-generic
sudo dpkg --audit
```

正式 `p2` 发布后，可从该 Release 下载 `download-and-install.sh`，先审阅，再执行：

```bash
chmod +x download-and-install.sh
sudo ./download-and-install.sh --tag ubuntu-26.04-bbrv3-7.0.0-30.30-p2 --reboot
```

省略 `--tag` 时只选择 GitHub 的最新稳定 Release，绝不会选择 prerelease；省略 `--reboot` 时只安装并更新 GRUB。脚本会下载该 Release 的全部资产、验证 `SHA256SUMS`、严格检查包白名单和依赖闭包，然后调用分阶段安装器。它不会使用 `--force-depends`，也不会执行 `apt -f` 来删除自定义内核。

安装器保留原装内核且不硬编码 GRUB 菜单标题。重启到目标内核后，systemd 自动执行运行验收：

```bash
journalctl -u bbrv3-verify -b --no-pager
sudo /var/lib/bbrv3-installer/install-bbrv3.sh test
```

验收包括目标 `uname -r`、BBRv3 模块版本和 vermagic、`fq`、`bbr` selector、本机 TCP 传输，以及匹配 OpenZFS 模块的加载和 vermagic。公网吞吐性能仍应另行测试。

## Secure Boot

内核模块使用该次内核构建时生成并嵌入内核的密钥签名，但 `linux-image-unsigned-*` 不是 Canonical 签名的 Secure Boot 镜像。启用 Secure Boot 的机器必须完成自定义镜像签名与信任注册，或在确认风险后禁用 Secure Boot；安装器检测到未满足条件时会停止。

## 补丁

Google 的 [BBRv3 分支](https://github.com/google/bbr/tree/v3)是实现基线。当前 Linux 7.0 / Ubuntu 移植补丁的来源、范围和 SHA-256 记录在 [`patches/README.md`](patches/README.md)。后续内核系列若不能精确应用该补丁，必须人工移植，不能仅放宽版本正则或强制应用。
