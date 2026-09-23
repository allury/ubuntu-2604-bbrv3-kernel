#!/bin/busybox sh
# shellcheck shell=dash

fail()
{
	echo "BBRV3_QEMU_FAIL: $*"
	/bin/busybox dmesg | /bin/busybox tail -n 120
	/bin/busybox poweroff -f
	while :; do /bin/busybox sleep 1; done
}

/bin/busybox mount -t proc proc /proc || fail 'cannot mount proc'
/bin/busybox mount -t sysfs sysfs /sys || fail 'cannot mount sysfs'
/bin/busybox mount -t devtmpfs devtmpfs /dev || fail 'cannot mount devtmpfs'
/bin/busybox ip link set lo up || fail 'cannot enable loopback'
/bin/busybox insmod /modules/sch_fq.ko || fail 'cannot load sch_fq'
/bin/busybox insmod /modules/tcp_bbr.ko || fail 'cannot load tcp_bbr'
/bin/busybox insmod /modules/spl.ko || fail 'cannot load OpenZFS spl module'
/bin/busybox insmod /modules/zfs.ko || fail 'cannot load OpenZFS zfs module'

module_version="$(/bin/busybox cat /sys/module/tcp_bbr/version 2>/dev/null)"
[ "$module_version" = 3 ] || fail "loaded tcp_bbr version is ${module_version:-missing}"
zfs_version="$(/bin/busybox cat /sys/module/zfs/version 2>/dev/null)"
expected_zfs_version="$(/bin/busybox cat /zfs-expected-version 2>/dev/null)"
[ -n "$zfs_version" ] || fail 'loaded OpenZFS module has no version'
[ "$zfs_version" = "$expected_zfs_version" ] ||
	fail "loaded OpenZFS version $zfs_version, expected $expected_zfs_version"
echo fq > /proc/sys/net/core/default_qdisc || fail 'cannot select fq'
echo bbr > /proc/sys/net/ipv4/tcp_congestion_control || fail 'cannot select bbr'
[ "$(/bin/busybox cat /proc/sys/net/core/default_qdisc)" = fq ] || fail 'fq was not retained'
[ "$(/bin/busybox cat /proc/sys/net/ipv4/tcp_congestion_control)" = bbr ] || fail 'bbr was not retained'

# Start the transfer with an empty kernel log, so that anything the kernel
# reports while BBRv3 carries traffic is told apart from boot messages.
/bin/busybox dmesg -c > /boot-dmesg.log || fail 'cannot read the kernel log'
taint_before="$(/bin/busybox cat /proc/sys/kernel/tainted)"
/bbrv3-socket-smoke || fail 'TCP socket smoke test failed'
taint_after="$(/bin/busybox cat /proc/sys/kernel/tainted)"
# Taint flags B (bad page), D (oops), W (warning) and L (soft lockup).
new_taint=$(( taint_after & ~taint_before & 17056 ))
[ "$new_taint" -eq 0 ] ||
	fail "kernel taint changed from $taint_before to $taint_after during the TCP transfer"
if /bin/busybox dmesg | /bin/busybox grep -Eq 'WARNING:|BUG:|Oops|Call Trace:|UBSAN:|general protection'; then
	fail 'the kernel reported a problem during the TCP transfer'
fi

echo "BBRV3_QEMU_PASS: $(/bin/busybox uname -r), module version $module_version"
echo "ZFS_QEMU_PASS: module version $zfs_version"
/bin/busybox poweroff -f
while :; do /bin/busybox sleep 1; done
