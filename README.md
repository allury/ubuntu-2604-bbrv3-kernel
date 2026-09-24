# Ubuntu 26.04 BBRv3 内核

基于 Canonical 已发布的 Ubuntu 26.04 generic 内核源码与配置，在完整 TCP 栈中合入 BBRv3，为 amd64 主机提供内核映像、模块、开发头文件及 ABI 匹配的真实 OpenZFS 模块包。

正式内核持续跟随 Ubuntu 已发布版本更新，具体版本见下方发布页。项目不是 Canonical 官方产品，也不包含其支持。

[查看正式版本](https://github.com/allury/ubuntu-2604-bbrv3-kernel/releases/latest)

目录职责、验证记录和后续维护方式见 [维护说明](docs/MAINTENANCE.md)。

## 安装

要求 Ubuntu 26.04、amd64、systemd 与 GRUB，适用于物理机和可更换内核的全虚拟化 VPS，不适用于共享宿主机内核的容器。需安装 curl、python3；启用 Secure Boot 的机器不能直接使用这些未签名内核镜像。

以下两种方式使用同一个固定版本的独立安装器，默认下载最新正式内核。安装成功后会重启，请先备份并确认服务商救援控制台可用。安装器保留已有内核，新内核先只试启动一次：起不来会自动回到原内核，开机验收通过后才成为默认启动项；不能试启动的情况见[独立安装器](#独立安装器)。

### 标准安装（推荐）

要求已安装官方回退内核；缺失时先运行 `sudo apt-get update && sudo apt-get install linux-image-generic`。

```bash
curl -fL https://raw.githubusercontent.com/allury/ubuntu-2604-bbrv3-kernel/installer-v1.2.0/installer/install.sh -o install-bbrv3.sh &&
sudo bash install-bbrv3.sh --reboot
```

### 跳过官方回退内核检查

仅在接受风险后使用。此参数只跳过官方回退内核存在性检查，不跳过校验和、依赖、系统环境和 Secure Boot 检查。没有可用回退内核时，启动失败可能需要救援控制台恢复。

```bash
curl -fL https://raw.githubusercontent.com/allury/ubuntu-2604-bbrv3-kernel/installer-v1.2.0/installer/install.sh -o install-bbrv3.sh &&
sudo bash install-bbrv3.sh --allow-no-fallback --reboot
```

建议执行前阅读下载的脚本。去掉 `--reboot` 可在安装完成后自行重启。追加 `--no-boot-once` 可关闭试启动。要固定安装 p2，追加 `--tag ubuntu-26.04-bbrv3-7.0.0-30.30-p2`。已运行目标内核时无需重复安装。

## 重启后检查

安装器注册开机验收服务；查看日志确认启动的是目标内核，BBRv3 版本为 3，匹配的 OpenZFS 模块可加载：

```bash
uname -r
cat /sys/module/tcp_bbr/version
journalctl -u bbrv3-verify -b --no-pager
sudo bash /var/lib/bbrv3-installer/install-bbrv3.sh test
```

预期内核以所选发布页为准。例如 `7.0.0-30.30-p2` 对应 `7.0.0-13002-generic`；不同源码版本的 p2 并非同一内核。试启动通过后，验收日志会注明新内核已成为默认启动项。

试启动时新内核若崩溃或挂不上根分区，会在 10 秒后自动重启回原内核，回到原内核的那次开机，验收日志会说明试启动未通过；若新内核卡住不动，在服务商面板重启一次即可回到原内核。未启用试启动时，启动失败需在 GRUB 菜单选择保留的原装内核；无回退内核则使用服务商救援环境。不要在新版本验收前删除旧内核。

## 自动编译与发布

每天定时检查 Ubuntu 官方已发布的内核候选版本（计划时间 02:23 UTC，即北京时间 10:23；GitHub 定时任务常延迟数小时）。同源版本和补丁修订已发布时跳过，运行摘要会注明本次没有构建。新版本依次执行：

1. 解析 Ubuntu 发布源，核对 BBRv3 补丁的 SHA-256 与维护者批准值，校验补丁能否精确应用，并记录补丁涉及文件相对审核基线的变化。
2. 预编译 OpenZFS，随后完整构建 Ubuntu generic 内核包和匹配 ZFS 包。
3. 验证包名、版本、架构、依赖、模块签名及校验和。
4. 在干净 Ubuntu 26.04 容器中真实安装包，并编译外部测试模块。
5. 在 QEMU 中启动产物，验证 BBRv3、OpenZFS 加载和 32 MiB TCP 传输，确认连接上报 BBR 版本 3，且传输期间内核没有报告警告。
6. 在 Ubuntu 26.04 云镜像虚拟机中用独立安装器的安装逻辑安装，经 GRUB 试启动和新生成的 initramfs 进入新内核，确认开机验收通过后新内核成为默认启动项。
7. 全部通过才创建正式 Release，不覆盖已有同名版本。

补丁不兼容时停止发布并创建移植问题，不保证未来所有内核均无需人工适配。服务器不会自动安装或重启；新正式版本发布后，主动执行上述安装命令即可更新。

## 独立安装器

`installer/install.sh` 从稳定 p2 安装逻辑派生，支持显式 `--allow-no-fallback` 和 `--no-boot-once`。当前固定标签为 `installer-v1.2.0`，旧版 `installer-v1.1.0`、`installer-v1.0.0` 保留；更新安装器不需要编译内核，也不修改已发布内核包或附带脚本。

安装器下载同一内核 Release 的文件，完整验证 `SHA256SUMS`，再运行自身附带的安装逻辑、BBR 启用脚本和配置。不执行内核附件中的安装脚本，也不从可变的 `main` 下载运行组件。历史附件仍保留以兼容旧安装器。

v1.2.0 起新内核先只试启动一次。安装器把当前运行的内核保留为 GRUB 默认启动项（`GRUB_DEFAULT=saved`，写在 `/etc/default/grub.d/99-bbrv3-installer.cfg`），用临时菜单项（`/boot/grub/custom.cfg`，与新内核的普通启动项相同，只多了 `panic=10`）启动一次新内核。开机验收通过且存在默认路由后，新内核才成为默认启动项，临时菜单项随即删除。

以下情况不做试启动并在安装时说明原因，行为同 v1.1.0，即新内核因版本号靠前直接成为默认启动项：`/boot/grub` 位于 btrfs、ZFS、LVM、软 RAID 等 GRUB 无法写入的位置；`GRUB_DEFAULT` 已被自定义；使用了 `--no-boot-once`。要恢复按菜单顺序启动，删除上述配置文件后运行 `sudo update-grub`。用 v1.2.0 安装过后，后续升级也请使用 v1.2.0 或更新的安装器，旧安装器不会移动 GRUB 保存的默认启动项。详见 [更新记录](installer/CHANGELOG.md)。

安装器改动和每个新内核都会在 BIOS 引导的 Ubuntu 26.04 云镜像虚拟机中完成安装与重启验收；安装器改动还会验证试启动失败后无人干预地回到原内核。这仍不等同于 UEFI、PV-GRUB 等所有服务商引导配置下的端到端验证。

## 源码与信任边界

- 内核：[Ubuntu 内核团队 resolute 仓库](https://git.launchpad.net/~ubuntu-kernel/ubuntu/+source/linux/+git/resolute)，精确发布标签；解析已签名的正式 APT 元数据，排除 proposed、backports 和 PPA。
- BBRv3：[Google BBR](https://github.com/google/bbr/tree/v3)；当前 Linux 7.0 移植补丁来自第三方 [byJoey/Actions-bbr-v3](https://github.com/byJoey/Actions-bbr-v3)，不是 Google 官方 Ubuntu 补丁。补丁存放在本仓库并记录来源提交；构建前核对其 SHA-256 与维护者批准值，执行精确应用检查，并在 Release 附件 `PATCH-BASELINE-DRIFT.txt` 中列出补丁涉及文件相对审核基线的 Ubuntu 改动，详见 [补丁策略](patches/README.md)。
- OpenZFS：Ubuntu 官方 `zfs-dkms` 源码，针对自定义 ABI 编译并使用该内核构建密钥签名。
- 构建与恢复：[构建恢复说明](docs/BUILD-RECOVERY.md)；[补丁策略](patches/README.md)。

SHA-256 用于校验下载一致性，不代替发布者身份认证；安装需要信任本仓库及其发布流程。内核镜像未获 Canonical 签名，模块签名不等于镜像满足 Secure Boot 要求。
