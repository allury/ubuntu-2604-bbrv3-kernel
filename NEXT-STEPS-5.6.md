# GPT-5.6 接手操作单（2026-09-05）

## p2 构建结果（2026-09-05 回填）

- Run：https://github.com/allury/ubuntu-2604-bbrv3-kernel/actions/runs/33967676484（六 job 全绿，含首次运行的 install-check 与 QEMU boot-smoke）
- Release：https://github.com/allury/ubuntu-2604-bbrv3-kernel/releases/tag/ubuntu-26.04-bbrv3-7.0.0-30.30-p2（稳定版，非 prerelease）
- 内核 release：`7.0.0-13002-generic`；包版本：`7.0.0-13002.30+bbrv3.2`
- 关键修复：Release 包含真实 `linux-main-modules-zfs-7.0.0-13002-generic`（本地签名 spl/zfs，vermagic 已验证），p1 的依赖缺陷已解决
- 发布元数据确认：BBR 模块 version=3；selector 为 `bbr`
- 同日完成第三方补丁等同性审计（docs/PATCH-AUDIT.md）与下版本自移植决策（docs/NEXT-VERSION-CHECKLIST.md）

## 用户已经完成的真实验收

历史构建：https://github.com/allury/ubuntu-2604-bbrv3-kernel/actions/runs/33938396949

历史 Release：https://github.com/allury/ubuntu-2604-bbrv3-kernel/releases/tag/ubuntu-26.04-bbrv3-7.0.0-30.30-p1

用户在 Ubuntu 26.04.1 amd64 VPS 上安装并启动了 `7.0.0-10030-generic`。已给出的证据包括：

- `uname -r`：`7.0.0-10030-generic`；
- `cat /sys/module/tcp_bbr/version`：`3`；
- 真实 HTTPS 连接的 `ss -ti`：显示 `bbr` 以及 `bbr:(bw, mrtt, pacing_gain, cwnd_gain)` 数据。

因此 BBRv3 的启动与真实 TCP 冒烟测试已成功，不要再次质疑它是否仍是 BBRv1。

## p1 的已确认缺陷

`linux-modules-7.0.0-10030-generic` 硬依赖 `linux-main-modules-zfs-7.0.0-10030-generic`，但 p1 Release 未提供该包。VPS 的首次 `dpkg -i` 留下未配置包，`apt-get install -f` 随后删除了自定义 image/modules。用户最后用临时占位包完成启动。

占位包只证明 BBRv3 路径可运行，不是可发布的依赖解决方案。不要删除 Ubuntu 的 ZFS 依赖，不要继续占位包，不要使用 `--force-depends`。

## 用户确定的 p2 技术路线

最终措辞是“内核对齐 Ubuntu 26.04，来源保持安全性”：

- 只接受 `resolute`、`resolute-updates`、`resolute-security`；拒绝 proposed/backports/PPA；
- 精确解析已发布 `linux` 源版本和 Launchpad tag；
- 完整合入 BBRv3 TCP 栈补丁并重编完整 generic 内核；
- 保留 Ubuntu 的 `linux-main-modules-zfs-$release` 依赖；
- 从 Ubuntu 26.04 的 `zfs-dkms` 构建真实 `spl.ko`/`zfs.ko`，针对自定义 ABI 本地签名并打包；
- p2 新 ABI 与 p1 并存；
- 干净系统安装、headers 外部模块编译、QEMU BBRv3/ZFS 加载均为每个正式版的自动门禁；
- 下一版通过全部门禁后发布稳定 Release，不再加 `--prerelease`。

对齐不表示 Canonical 官方或 Canonical 签名。内核镜像仍是 `linux-image-unsigned-*`。

## 接手后的顺序

1. 先读取当前分支、最新提交、Actions run 和完整失败日志。不要凭推测修改。
2. 确认 `scripts/resolve-source.sh` 的行为测试通过；手动版本和 auto 都必须来自允许的 Ubuntu APT 源。
3. 若 ZFS 构建失败，定位 `debian/scripts/dkms-build` 或 OpenZFS `make.log` 的第一个真实错误。保持 Ubuntu `zfs-dkms` 来源，不要换不明第三方仓库。
4. 检查发布目录必须包含：image、modules、两类 headers、buildinfo、可选 rust，以及精确匹配的 `linux-main-modules-zfs-$release`。
5. `install-check` 必须真实安装全部 `.deb`；不能只做 `dpkg-deb -I`。确认 `apt-get --simulate --no-remove`、真实 install、`apt-get check`、`dpkg --audit`、ZFS signer/vermagic、外部 headers 编译均成功。
6. `boot-smoke` 必须从 Release artifact 解包精确 vmlinuz 和模块，在 QEMU 内加载 `tcp_bbr`、`spl`、`zfs`，检查 BBRv3 `version=3` 并完成 TCP 传输。
7. 只有 build、install-check、boot-smoke 全绿才允许 publish 稳定 Release。失败不得手工上传未经同等验证的 `.deb`。
8. 成功后把 run、commit、Release、内核 release、包版本、ZFS 源版本和 SHA-256 回填本文件及 README；把 p1 Release 明确标成历史缺陷 prerelease。

## VPS 安装注意事项

用户的 `/boot` 当前只看到 `7.0.0-10030-generic`，`vmlinuz.old` 和 `initrd.img.old` 也指向同一版本；这不是多份内核，而是缺少真正回退内核的迹象。安装 p2 前要求：

```bash
sudo apt-get update
sudo apt-get install linux-image-generic
sudo dpkg --audit
```

新 `download-and-install.sh` 只选择稳定 Release，下载全部资产并验 SHA-256。`install-bbrv3.sh` 会拒绝损坏的 dpkg 状态、缺少真实 ZFS 包、混合版本、意外包以及没有 Canonical 回退内核的机器。启动后 systemd 自动测试 BBRv3 和 ZFS。

用户没有提供 VPS 访问凭据，也没有授权代理登录或重启；服务器安装、GRUB 选择和重启由用户执行。不要删除旧内核。

## 自动更新边界

每天 02:23 UTC 检查 Ubuntu 26.04 已发布的 `linux-image-generic` 候选。新 ABI 必须重复所有门禁；ZFS 默认包含不等于可以省略重新编译/加载测试。遇到新内核系列或 TCP 补丁冲突时创建移植 issue 并停止，不允许模糊 patch。

GitHub 自动构建不等于 VPS 自动升级。除非用户以后单独授权服务器端自动安装和重启，否则只发布 Release，不进行无人值守生产升级。
