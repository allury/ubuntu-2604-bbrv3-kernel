# Ubuntu 26.04 BBRv3 内核

基于 Canonical 已发布的 Ubuntu 26.04 generic 内核源码与配置，在完整 TCP 栈中合入 BBRv3，为 amd64 主机提供内核映像、模块、开发头文件及 ABI 匹配的真实 OpenZFS 模块包。

当前正式版：`ubuntu-26.04-bbrv3-7.0.0-30.30-p2`，内核 `7.0.0-13002-generic`。构建代码以通过验收的提交 `db2c4b0` 为基准。项目不是 Canonical 官方产品，也不包含其支持。

[查看正式版本](https://github.com/allury/ubuntu-2604-bbrv3-kernel/releases/latest)

## 安装

要求 Ubuntu 26.04、amd64、systemd 与 GRUB，适用于物理机和可更换内核的全虚拟化 VPS，不适用于共享宿主机内核的容器。需安装 curl、python3；启用 Secure Boot 的机器不能直接使用这些未签名内核镜像。

以下两种方式使用同一个固定版本的独立安装器，默认下载最新正式内核。安装成功后会重启，请先备份并确认服务商救援控制台可用。安装器保留已有内核，不修改 GRUB 默认选项；自定义引导配置可能需要手动选择目标内核。

### 标准安装（推荐）

要求已安装官方回退内核；缺失时先运行 `sudo apt-get update && sudo apt-get install linux-image-generic`。

```bash
curl -fL https://raw.githubusercontent.com/allury/ubuntu-2604-bbrv3-kernel/installer-v1.0.0/installer/install.sh -o install-bbrv3.sh &&
sudo bash install-bbrv3.sh --reboot
```

### 跳过官方回退内核检查

仅在接受风险后使用。此参数只跳过官方回退内核存在性检查，不跳过校验和、依赖、系统环境和 Secure Boot 检查。没有可用回退内核时，启动失败可能需要救援控制台恢复。

```bash
curl -fL https://raw.githubusercontent.com/allury/ubuntu-2604-bbrv3-kernel/installer-v1.0.0/installer/install.sh -o install-bbrv3.sh &&
sudo bash install-bbrv3.sh --allow-no-fallback --reboot
```

建议执行前阅读下载的脚本。去掉 `--reboot` 可在安装完成后自行重启。要固定安装 p2，追加 `--tag ubuntu-26.04-bbrv3-7.0.0-30.30-p2`。已运行目标内核时无需重复安装。

## 重启后检查

安装器注册开机验收服务；查看日志确认启动的是目标内核，BBRv3 版本为 3，匹配的 OpenZFS 模块可加载：

```bash
uname -r
cat /sys/module/tcp_bbr/version
journalctl -u bbrv3-verify -b --no-pager
sudo bash /var/lib/bbrv3-installer/install-bbrv3.sh test
```

p2 的预期内核为 `7.0.0-13002-generic`。若启动失败，在 GRUB 选择保留的原装内核；无回退内核则使用服务商救援环境。不要在新版本验收前删除旧内核。

## 自动编译与发布

每天 02:23 UTC（北京时间 10:23）检查 Ubuntu 官方已发布的内核候选版本；同源版本和补丁修订已发布时跳过。新版本依次执行：

1. 解析 Ubuntu 发布源并校验 BBRv3 补丁能否精确应用。
2. 预编译 OpenZFS，随后完整构建 Ubuntu generic 内核包和匹配 ZFS 包。
3. 验证包名、版本、架构、依赖、模块签名及校验和。
4. 在干净 Ubuntu 26.04 容器中真实安装包，并编译外部测试模块。
5. 在 QEMU 中启动产物，验证 BBRv3、OpenZFS 加载和 TCP 传输。
6. 全部通过才创建正式 Release，不覆盖已有同名版本。

补丁不兼容时停止发布并创建移植问题，不保证未来所有内核均无需人工适配。服务器不会自动安装或重启；新正式版本发布后，主动执行上述安装命令即可更新。

## 独立安装器

`installer/install.sh` 从稳定 p2 安装逻辑派生，增加显式 `--allow-no-fallback`。固定标签 `installer-v1.0.0` 管理安装器版本；更新安装器不需要编译内核，也不修改 p2 的安装包或附带脚本。

安装器下载同一内核 Release 的文件，完整验证 `SHA256SUMS`，再运行自身附带的安装逻辑。不从可变的 `main` 下载并混用安装组件。内核构建流程中的历史脚本保持稳定基线，README 的命令使用独立入口。

安装器测试覆盖参数传递及回退检查分支，不等同于所有服务器的端到端重启验证。

## 源码与信任边界

- 内核：[Ubuntu 内核团队 resolute 仓库](https://git.launchpad.net/~ubuntu-kernel/ubuntu/+source/linux/+git/resolute)，精确发布标签；解析已签名的正式 APT 元数据，排除 proposed、backports 和 PPA。
- BBRv3：[Google BBR](https://github.com/google/bbr/tree/v3)；当前 Linux 7.0 移植补丁来自第三方 [byJoey/Actions-bbr-v3](https://github.com/byJoey/Actions-bbr-v3)，不是 Google 官方 Ubuntu 补丁，补丁内容以 SHA-256 固定并执行精确应用检查。
- OpenZFS：Ubuntu 官方 `zfs-dkms` 源码，针对自定义 ABI 编译并使用该内核构建密钥签名。
- 构建与恢复：[构建恢复说明](docs/BUILD-RECOVERY.md)；[补丁策略](patches/README.md)。

SHA-256 用于校验下载一致性，不代替发布者身份认证；安装需要信任本仓库及其发布流程。内核镜像未获 Canonical 签名，模块签名不等于镜像满足 Secure Boot 要求。
