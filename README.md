# Ubuntu 26.04 BBRv3 kernel

这个仓库构建的是完整的 Ubuntu 26.04 **amd64 generic 内核**：包含内核映像、内核模块和两类 headers 包。它不是把 BBRv3 单独编译成可加载的 `tcp_bbr.ko`。

初始目标为 Ubuntu 源码包 `linux 7.0.0-30.30`（对应发行版内核 ABI `7.0.0-30-generic`）。为了不覆盖 Canonical 的回退内核，产物使用自定义 ABI：

- 内核 release：`7.0.0-10030-generic`
- Debian 包版本：`7.0.0-10030.30+bbrv3.1`
- GitHub Release 标签：`ubuntu-26.04-bbrv3-7.0.0-30.30-p1`

只有 GitHub Actions 完整通过并发布的 Release 才是可安装产物；仓库中的脚本和补丁本身不代表已完成编译或运行验证。

## 工作流逻辑

1. 手动运行默认固定构建 `7.0.0-30.30`；定时任务则从 Ubuntu 26.04 已签名的 APT 元数据中读取 `linux-image-generic` 的候选依赖，避免把尚未发布的 Launchpad Git tag 当成正式更新。
2. 克隆对应的精确 Launchpad tag，例如 `Ubuntu-7.0.0-30.30`，并核对源包 changelog 版本。
3. 对完整 TCP 栈 BBRv3 补丁执行精确的 `git apply --check --whitespace=error`；不会使用模糊合并。
4. 修改 Ubuntu 打包 ABI 后，执行 `fakeroot debian/rules clean` 和 `fakeroot debian/rules binary-generic binary-headers`，产出映像、模块、flavour headers、common headers 和 buildinfo。
5. 校验包名、版本、架构、`tcp_bbr` 模块路径、模块 `version=3`、vermagic、BBR/FQ 内核配置以及 SHA-256。
6. 只在全部校验成功时创建不可覆盖的 GitHub **pre-release**，并同时附上精确补丁、源码 tag/commit 和 SHA-256 元数据。

构建使用 `do_mainline_build=true` 来排除 Ubuntu 的外部 DKMS、工具、源码包和 debug 包，以控制 CI 资源；这**不会**把 BBRv3 降级为独立模块，也不会跳过通用内核映像、内核模块或 headers 的编译。TCP 栈修改和 `vmlinuz` 会一起重新编译。

## 后续 Ubuntu 内核更新

每天的定时任务会检查发行版实际发布的 `linux-image-generic` 候选版本。若新版本能通过精确补丁应用、完整编译和产物验证，会自动发布该版本的自定义内核。

若 Ubuntu 修改了相关 TCP 代码导致补丁不能精确应用，工作流会失败并创建（或复用）一个 porting issue，且**不会发布二进制包**。这是一项安全边界：不能用自动模糊 patch 来假装未来内核仍然正确支持 BBRv3。完成真实移植后，添加相应版本补丁并提高 `scripts/resolve-source.sh` 中的 `patch_revision`，再重新运行工作流。

## 首次编译

在 GitHub 中打开 **Actions → Build Ubuntu 26.04 BBRv3 kernel → Run workflow**，保留默认 `7.0.0-30.30` 即可。完整内核构建需要较长时间和较多 GitHub Actions 磁盘空间；构建失败时不要安装任何不完整 artifact。

通过编译和静态包校验的产物仍是 **pre-release**，不是已经完成启动兼容性认证的正式版。应先在隔离 VM 安装、重启、确认 `uname -r` / `modinfo`、进行基本 TCP 传输和检查 `dmesg`，再决定是否在生产服务器安装。

## 安装到服务器

新增一键辅助脚本 `scripts/install-bbrv3.sh`，尚待 VM 验收。下载同一个已验收 Release 的全部资产，在该目录执行（需要 python3、mokutil、systemd 和 GRUB）：

```bash
sudo bash ./install-bbrv3.sh install
# 确认 GRUB 启动目标及控制台/回退路径后，可改用下面命令安装并立即重启：
# sudo bash ./install-bbrv3.sh install --reboot
```

脚本不更改 GRUB 默认项，请确保启动目标自定义内核。重启后自动验证，查看 `journalctl -u bbrv3-verify -b --no-pager`；也可 `sudo /var/lib/bbrv3-installer/install-bbrv3.sh test` 重测。包括运行内核、已加载 BBR 模块版本、sysctl 和本机 TCP 冒烟测试，不代表公网性能测试通过。拒绝正在运行的同 release 原地安装。最早的旧构建不含新脚本，可从仓库同时获取新版 install/enable 脚本；不得把编译成功当成已完成安装验收。

后续具体工作见 [GPT-5.6 操作单](NEXT-STEPS-5.6.md)，尤其先确认 ZFS 拆分包依赖与 VM 启动。

从同一个成功 Release 下载全部 `.deb`、`SHA256SUMS`、`bbrv3.sysctl.conf` 和 `enable-bbrv3.sh` 到一个空目录。以下操作应在 Ubuntu 26.04 amd64 服务器执行，并保留 Canonical 内核作为 GRUB 回退项：

```bash
sha256sum -c SHA256SUMS
sudo apt install ./*.deb
sudo update-grub
sudo reboot
```

重启后先确认已经运行自定义内核；初始版本预期为 `7.0.0-10030-generic`：

```bash
uname -r
modinfo -F version tcp_bbr
# 必须显示 3
sudo ./enable-bbrv3.sh "$(uname -r)"
sysctl net.ipv4.tcp_congestion_control
cat /proc/sys/net/ipv4/tcp_available_congestion_control
```

BBRv3 的 selector 名称是 `bbr`，不是 `bbr3`。辅助脚本会确认正在运行的模块版本、vermagic、`fq` 默认队列规则和 `bbr` selector 后才完成配置。

这些包默认是未签名的 `linux-image-unsigned-*` 包。启用 Secure Boot 的机器必须先自行签名并通过 MOK 信任该内核，或在确认风险后禁用 Secure Boot；否则不要尝试启动它。

## 补丁来源与范围

Google 的 [BBRv3 分支](https://github.com/google/bbr/tree/v3)是实现基线。仓库中保存的是面向 Linux 7.0 / Ubuntu `7.0.0-30.30` 的完整 TCP 栈移植补丁，具体来源和不可变 SHA-256 记录在 [`patches/README.md`](patches/README.md)。它修改 TCP 核心与 BBR 实现，必须同整个内核一起构建。

当前工作流只支持 `amd64` 和 Ubuntu 26.04 的 `7.0.0-*` 通用内核线。
