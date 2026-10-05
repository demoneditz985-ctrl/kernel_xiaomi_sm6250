#!/system/bin/sh
# Shadow Kernel - Vortex FR
# Apply early tunables before zygote starts (network + vm).
# (KernelSU/Magisk module entry point.)

# Enable BBR early so the network stack starts with it
if [ -f /proc/sys/net/ipv4/tcp_congestion_control ]; then
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1
fi

exit 0
