#!/system/bin/sh
# Shadow Kernel - Vortex FR
# ShadowTweaks : runtime performance / power tunables
# Applied on late boot. Values are conservative and safe for daily use,
# gaming and better battery backup on miatoll (POCO M2 Pro).
# Flash this module with KernelSU or Magisk.

MODDIR=${0%/*}

# --- network: BBR congestion control for lower latency / better throughput ---
if [ -f /proc/sys/net/ipv4/tcp_congestion_control ]; then
    # make sure the bbr module is available, then switch to it
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_fastopen=3 >/dev/null 2>&1
fi

# --- memory: tune for smoothness with zram (already enabled in kernel) ---
if [ -f /proc/sys/vm/swappiness ]; then
    sysctl -w vm.swappiness=100 >/dev/null 2>&1
    sysctl -w vm.dirty_background_ratio=10 >/dev/null 2>&1
    sysctl -w vm.dirty_ratio=20 >/dev/null 2>&1
    sysctl -w vm.dirty_expire_centisecs=1000 >/dev/null 2>&1
    sysctl -w vm.vfs_cache_pressure=50 >/dev/null 2>&1
fi

# --- scheduler: better wakeup fairness / interactivity for gaming ---
if [ -f /proc/sys/kernel/sched_wakeup_granularity_ns ]; then
    sysctl -w kernel.sched_wakeup_granularity_ns=4000000 >/dev/null 2>&1
fi
if [ -f /proc/sys/kernel/sched_min_granularity_ns ]; then
    sysctl -w kernel.sched_min_granularity_ns=3000000 >/dev/null 2>&1
fi
if [ -f /proc/sys/kernel/sched_migration_cost_ns ]; then
    sysctl -w kernel.sched_migration_cost_ns=500000 >/dev/null 2>&1
fi

# --- reduce unnecessary logging / debug noise for battery ---
if [ -f /proc/sys/kernel/printk ]; then
    sysctl -w kernel.printk=4 4 1 7 >/dev/null 2>&1
fi

echo "ShadowTweaks: applied by Vortex FR" >> /dev/kmsg 2>/dev/null

exit 0
