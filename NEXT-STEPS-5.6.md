# GPT-5.6 接手操作单（2026-09-05 更新）

本文更新旧 HANDOFF-ZH.md 的状态；旧文保留作历史审查，不应重新修复已经解决的问题。

## 实际状态

首次构建：https://github.com/allury/ubuntu-2604-bbrv3-kernel/actions/runs/33938396949

构建提交 0e1fb419357a7e4e950c19db30ff8f6b1ab2b2bb；本次检查 build job 101231687193 仍在编译。尚无成功安装、启动或网络测试证据。当前新增的安装脚本不会自动进入这次旧提交的产物。

已修复：YAML、多参数调用、heredoc、公共 headers 目标及 all 架构、管道 SIGPIPE、上传版本号、dispatch 输入、Release 查询错误处理。已采用完整 Ubuntu 内核编译与 prerelease。不要回到独立模块方案。

本次新增 scripts/install-bbrv3.sh：从已下载的同一个 Release 目录安装，校验哈希/包版本、模拟 APT 依赖安装、保留原内核；可显式 --reboot；systemd 在启动后校验预期 uname、加载模块版本 3、bbr/fq 和本机 TCP 传输。不会修改 GRUB 默认项；用户需确认目标项或通过控制台选择。不是无需控制台的通用无人值守部署器。

## 接手后按顺序操作

1. 读取当前 run 结果及完整日志。不要取消仍在正常编译的 run，也不要为加入脚本重复编译整个内核。失败先定位首个真实错误。
2. 最高优先级核查包依赖闭包。精确源码 debian.master/control.d/vars.generic 包含 linux-main-modules-zfs-PKGVER-ABINUM-generic 依赖；do_mainline_build=true 关闭 DKMS，可能产出无法安装的 custom ABI 依赖。检查最终 dpkg-deb -f 的 Depends，不能只靠源码推断必然失败。当前 verify-artifacts.sh 未覆盖这项。若确实缺包，正确构建对应组件或明确排除 ZFS 并修正依赖/文档；不允许 apt --force-depends。使用 ZFS 根文件系统的机器不能安装缺 ZFS 的内核。
3. 在干净 Ubuntu 26.04 amd64 容器做 apt-get update 与 apt-get --simulate --no-remove install ./*.deb；再在隔离 VM 实际安装和启动。补上 CI 安装依赖检查，失败不得发布。收紧产物包名白名单及 vermagic 首字段精确匹配。实测 headers 支持外部模块构建。
4. 对新增安装脚本做 VM 验收：非 root、错误系统/架构、容器、Secure Boot、哈希错误、混合版本、缺依赖都应停止；成功安装后启动目标内核，检查 journalctl -u bbrv3-verify -b。错误内核应报错且不配置 bbr。另测 GRUB 默认配置/回退：本版不强设默认，需控制台选择；若实现 grub-reboot，须从真实 grub.cfg 获取目标 ID 并验证，不要硬编码菜单标题。保留原内核；自动回退仅凭 grub-reboot 不能保证。
5. 安装脚本的 loopback TCP 是冒烟测试；补充 VM 对端持续 TCP 传输、丢包/重传、dmesg BUG/Oops/WARN 检查。检查网卡/存储驱动、initramfs、DKMS 和 ZFS。模块 version=3 不是算法移植正确性的证明，仍需审查第三方补丁与 Google BBRv3 差异。
6. 旧 run 成功后先验收包。新增脚本可从当前仓库获取配合同一个 Release 的 deb 使用；旧 Release 的 enable 脚本应换成本次有 sysfs 校验的版本。不要覆盖已发布资产；若需包含新脚本的发行包，发布明确的新修订并记录原二进制哈希/来源，或在下次完整构建使用新的打包工作流。未经过 VM 测试前保留 prerelease。

## 自动更新审查结论

方向正确但不能宣称已经完整验收：schedule 每天 02:23 UTC（北京时间 10:23，触发可能延迟），无 push 触发。定时传 auto；手动默认仍是 7.0.0-30.30。从 ubuntu:26.04 APT 的 linux-image-generic 候选依赖映射精确 tag，严格应用补丁、构建、验证，再按 source+patch_revision 标签跳过已有 Release。

需要补齐：

- 在真实 Ubuntu 容器运行 auto，保存 apt-cache policy/show 输出与源配置。显式限定 resolute、resolute-updates、resolute-security，拒绝 proposed/其他发行版。确认签名 image 的 Source 可能是 linux-signed，不能未经核实用二进制版本当 linux 源码版本；从对应 unsigned image 或源包元数据交叉核对。
- 当前正则只接受 7.0.0-ABI.upload；内核系列/源码包/修订格式变化会失败，不能自动适配。增加清楚的失败报告；遇到新系列要人工移植，不能仅放宽正则。
- 为 auto/no-update/new-upload/跨系列/404/403/补丁冲突添加小型可重复行为测试。补丁冲突已有 issue，解析失败及构建失败还没有统一通知逻辑。
- 同 ABI 新上传包版本可递增，但 uname 相同，安装会替换旧自定义模块；本次安装器拒绝正在运行的同 release 原地安装。应定义构建修订与可回退的 release/ABI 方案，不能只提高 patch_revision 就宣称两版并存。
- do_mainline_build=true 也关闭 Ubuntu 部分检查（do_skip_checks），不仅是省略工具。明确配置差异，保存 .config、精确源码/补丁/构建脚本与许可证信息，补 VM 启动门禁。
- 每个 job 最小权限、Actions 固定 commit SHA、失败日志/磁盘指标归档。不要改变正在运行的 job；后续提交不影响旧 run。
- GitHub 自动构建不等于服务器自动升级；不添加服务器定时安装/重启任务。

## 用户授权

已授权仓库修复、推送、Actions 构建与安装脚本开发。未提供服务器访问，也未授权实际服务器安装或重启。用户准备交给 GPT-5.6 后续实操；按上述顺序完成验证，报告实际结果，不要把静态检查当成已成功启用 BBRv3。
