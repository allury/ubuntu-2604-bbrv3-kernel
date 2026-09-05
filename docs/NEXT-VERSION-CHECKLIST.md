# 版本更新清单

本文件规定后续 Ubuntu 内核版本跟进的固定流程与下一版本的既定决策。自动部分由 CI 承担，人工部分仅在新版本补丁无法精确应用时触发。

## 自动流程（无人工介入）

每日 02:23 UTC，工作流检查 `resolute`、`resolute-updates`、`resolute-security` 中 `linux-image-generic` 的当前候选版本：

1. 已存在同一源版本与补丁修订的 Release：跳过；
2. 新版本且现有补丁可精确应用（`git apply --check --whitespace=error`）：完整重建并重复全部发布门禁（含 ZFS 重编译与 QEMU 启动测试），全绿后发布新正式 Release；
3. 补丁无法精确应用：停止发布并创建 porting issue，进入下述人工流程。

## 人工流程（下版本既定决策）

**决策：下一版本起，BBRv3 补丁改为基于 Google 官方 v3 源码自行移植，终止对第三方移植（byJoey/Actions-bbr-v3）的依赖。** 触发条件为上文第 3 种情形。

### 移植步骤

1. 基线：`google/bbr` 仓库 `v3` 分支（当期快照 tag，如 `bbrv3-2025-03-18`，基于 Linux 6.13.7）；对照原版取自 `gregkh/linux` 对应 stable tag。
2. 计算官方增量（v3 − 原版），限定 16 个 TCP 核心文件范围。
3. 对目标 Ubuntu 源码 tag 逐文件适配并生成 `patches/bbrv3-ubuntu-<新源版本>.patch`。
4. 适配时优先核对以下已知的版本适配点（7.0 审计结论，新版本须逐项重新确认）：
   - `ecn_flags` 位空间与 `TCP_ECN_LOW`、`TCP_ECN_ECT_PERMANENT` 编号；
   - ECN 模式 API（7.0 为 `tcp_ecn_mode_any()`，替代 `TCP_ECN_OK` 位检查）；
   - ECN 发送 API（7.0 为 `INET_ECN_xmit_ect_1_negotiation()`）;
   - `__tcp_send_ack()` 签名；
   - `tcp_info` 观测位（7.0 为 `tcpi_options2` + `TCPI_OPT2_ECN_LOW`）；
   - `tcp_ecn_send_syn` 的文件落点（6.13 后拆分至 `include/net/tcp_ecn.h`）；
   - 发包在途记录与速率采样记账（`tcp_set_tx_in_flight`、`rs->tx_in_flight`、`rs->prior_lost`）；
   - `tcp_tso_autosize()` 签名与导出形式；
   - Kconfig：延续本次决策，不提供 Google 树中仅用于对比测试的 BBRv1 配置项（`TCP_CONG_BBR1`）。
5. 修改 `scripts/resolve-source.sh` 的 `patch_revision`（+1），生成新的不可变 Release 标签序列。

### 验证（全部复用，不因移植方式改变）

- 补丁精确应用检查；全量编译；
- 包校验（名称、版本、架构、依赖闭包、SHA-256、vermagic、BBRv3 `version=3`）；
- 干净 Ubuntu 26.04 容器真实安装（`dpkg --audit` 为空）；
- QEMU 启动加载 `tcp_bbr`、`spl`、`zfs` 并完成 TCP 传输；
- 建议对自制补丁重复一次等同性审计（方法见 [`PATCH-AUDIT.md`](PATCH-AUDIT.md)），确认与 Google 官方实现一致。

### 文档回填（每个正式版发布后）

- README：当前版本号、内核 release、来源表中补丁来源改为"基于 Google 官方 v3 源码自行移植"；
- 本文件与 `NEXT-STEPS-5.6.md`：追加 run id、Release tag、日期、包版本、ZFS 源版本与 SHA-256。

### 安装器改进（已实现）

- `install-bbrv3.sh` 已支持 `--allow-no-fallback` 显式跳过参数：默认仍强制要求 Canonical 原装回退内核，使用该参数时打印醒目风险警告（无回退内核时启动失败需服务商救援模式恢复）并继续安装；`download-and-install.sh` 同名参数可透传。`dpkg --audit` 检查不提供跳过途径。
- `verify-artifacts.sh` 生成的 Release 说明（`RELEASE-NOTES.md`）已改为中文。

## 保持不变的部分

以下环节与本文件决策无关，任何版本更新均不改动：

- 版本解析（`resolve-source.sh` 的 resolute 白名单与 proposed/backports 排除）；
- 发布门禁与失败即停策略；
- OpenZFS 打包链路（Ubuntu `zfs-dkms` 源码、本地签名、ABI 精确匹配）；
- 安装器（`download-and-install.sh`、`install-bbrv3.sh`）与回退保护；
- 加密检查点保存与 `resume_run_id` 恢复机制。

## 版本历史

| 版本 | 源版本 | 补丁来源 | 状态 |
|---|---|---|---|
| p1 | 7.0.0-30.30 | byJoey 移植 | 历史缺陷 prerelease（缺 ZFS 依赖包） |
| p2 | 7.0.0-30.30 | byJoey 移植（经等同性审计） | 当前构建中（run 33967676484） |
| 下一版 | 待 Ubuntu 发布 | Google 官方 v3 自行移植 | 本文件决策 |
