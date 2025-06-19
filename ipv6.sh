#!/bin/bash
set -euo pipefail

# 检查root权限
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请使用sudo或root权限运行此脚本" >&2
    exit 1
fi

# 自动识别主网口
detect_main_nic() {
    # 优先通过默认路由识别
    local nic=$(ip route show default | awk '/default/ {print $5}' | head -n1)
    #  fallback到常见网口
    if [ -z "$nic" ]; then
        local common_nics=("eth0" "ens3" "ens192" "enp0s3")
        for n in "${common_nics[@]}"; do
            if ip link show "$n" &>/dev/null; then
                nic="$n"
                break
            fi
        done
    fi
    # 验证网口存在
    if [ -z "$nic" ] || ! ip link show "$nic" &>/dev/null; then
        echo "错误：无法识别主网口，请手动指定（示例：$0 eth0）" >&2
        exit 1
    fi
    echo "$nic"
}

# 主网口
main_nic=${1:-$(detect_main_nic)}
echo "检测到主网口：$main_nic"

# 临时设置IPv6网关
echo "正在临时设置IPv6网关为 fe80::1..."
ip -6 route add default via fe80::1 dev "$main_nic" || {
    echo "错误：设置路由失败，可能原因："
    echo "  1. fe80::1 不是有效网关"
    echo "  2. 网口 $main_nic 不支持此网关"
    exit 1
}

# 验证设置
echo "IPv6网关临时设置完成！"
echo "当前IPv6路由："
ip -6 route show | grep default

# 提供清理命令
echo -e "\n如需撤销临时设置，执行："
echo "ip -6 route del default via fe80::1 dev $main_nic"
