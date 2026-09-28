#!/usr/bin/env bash
# Turn the VM_NETWORK_RESULT lines of a network-scenario console log into a
# Chinese Markdown report, one comparison table per link profile.
set -euo pipefail

usage='Usage: vm-network-report.sh <console-log> <report.md>'
console_log="${1:?$usage}"
report="${2:?$usage}"

results="$(grep -aoE 'VM_NETWORK_RESULT: [^[:cntrl:]]*' "$console_log" | sed 's/^VM_NETWORK_RESULT: //' || true)"
[[ -n "$results" ]] || { printf 'ERROR: %s has no network results.\n' "$console_log" >&2; exit 1; }

{
  printf '# 网络行为报告\n\n'
  printf '%s\n\n' '在同一台 Ubuntu 26.04 云镜像虚拟机（KVM）中，用三个网络命名空间搭建“发送端 → 路由器 → 接收端”链路：路由器用 netem 对数据方向限速，瓶颈缓冲按带宽时延积（BDP）设定，可叠加随机丢包，并把 ACK 方向延迟一个往返时间；发送端统一使用 fq。先在云镜像自带的官方内核上测 CUBIC 和 BBR（即 BBRv1），安装 BBRv3 内核并通过试启动后，再测 CUBIC 和 BBR（即 BBRv3）。'
  printf '%s\n\n' '这是虚拟机内的受控对比，适合比较同一条件下各算法的相对表现，不代表真实公网上的绝对速度，也不是发布门槛。吞吐按对端已确认的数据计算，“后半段吞吐”不含启动阶段；重传率为重传字节占发送字节的比例。'
  awk '
    {
      delete field
      for (i = 1; i <= NF; i++) {
        split_at = index($i, "=")
        field[substr($i, 1, split_at - 1)] = substr($i, split_at + 1)
      }
      profile = field["profile"]
      if (!(profile in seen)) {
        seen[profile] = 1
        order[++profiles] = profile
        title[profile] = sprintf("## %s：%s Mbit/s，往返 %s ms，丢包 %s%%，缓冲 %s BDP，每次 %s 秒",
          profile, field["rate_mbit"], field["rtt_ms"], field["loss_pct"], field["buffer_bdp"], field["seconds"])
      }
      algorithm = field["cc"] == "bbr" ? "BBRv" field["bbr_version"] : toupper(field["cc"])
      rows[profile] = rows[profile] sprintf("| %s | %s | %s | %s | %s%% | %s | %s | %s |\n",
        field["kernel"], algorithm, field["goodput_mbit"], field["steady_mbit"], field["retrans_pct"],
        field["srtt_ms"], field["min_rtt_ms"], field["bbr_bw_mbit"])
      if (field["offloads"] != "off") offloads_on = 1
    }
    END {
      for (i = 1; i <= profiles; i++) {
        profile = order[i]
        print title[profile]
        print ""
        print "| 内核 | 算法 | 全程吞吐 (Mbit/s) | 后半段吞吐 (Mbit/s) | 重传率 | 平滑 RTT (ms) | 最小 RTT (ms) | BBR 带宽估计 (Mbit/s) |"
        print "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |"
        printf "%s\n", rows[profile]
      }
      if (offloads_on) print "注意：部分虚拟网卡的分段卸载未能关闭，按报文计数的瓶颈缓冲可能偏大。"
    }
  ' <<<"$results"
} > "$report"
