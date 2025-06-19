#!/bin/bash
set -euo pipefail

# ==================== 基础检查 ====================
# 检查root权限
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请使用sudo或root权限运行此脚本" >&2
    exit 1
fi

# 检查网络工具依赖
if ! command -v ip &>/dev/null; then
    echo "错误：系统缺少ip命令（请安装iproute2：apt install iproute2 或 yum install iproute2）" >&2
    exit 1
fi

# ==================== 系统检测模块 ====================
detect_system() {
    # 初始化默认值
    OS_FAMILY="unknown"
    USE_NETPLAN=0
    NM_ACTIVE=0

    # 检测发行版
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-}"
        OS_VERSION="${VERSION_ID:-0}"
        OS_ID_LIKE="${ID_LIKE:-}"
    fi

    # 确定系统家族（Debian/RHEL/其他）
    case "$OS_ID" in
        ubuntu|debian) OS_FAMILY="debian" ;;
        rhel|centos|fedora|almalinux|rocky) OS_FAMILY="rhel" ;;
        *)
            # 通过ID_LIKE间接判断（如阿里alinux的ID_LIKE包含rhel）
            if [[ "$OS_ID_LIKE" == *"rhel"* ]]; then
                OS_FAMILY="rhel"
            elif [[ "$OS_ID_LIKE" == *"debian"* ]]; then
                OS_FAMILY="debian"
            else
                echo "警告：检测到未知发行版，尝试通用配置..."
                OS_FAMILY="generic"
            fi
            ;;
    esac

    # 检测Netplan（仅Debian家族）
    if [[ "$OS_FAMILY" == "debian" && -d /etc/netplan && "$OS_VERSION" > "19.10" ]]; then
        USE_NETPLAN=1
    fi

    # 检测NetworkManager是否运行（影响服务重启）
    if systemctl is-active --quiet NetworkManager; then
        NM_ACTIVE=1
    fi
}

# ==================== 网卡检测模块 ====================
detect_nics() {
    # 过滤规则：保留物理/虚拟业务网卡，排除虚拟网桥/容器/回环
    local nic_filter="^(ens|eth|enp|enx|vnet)[0-9a-z]*$"
    local exclude_filter="lo|docker|br-|veth|virbr|tun|tap"

    # 获取所有符合条件的网卡
    local raw_nics=$(ip link show | awk -F': ' '{print $2}' | grep -E "$nic_filter" | grep -Ev "$exclude_filter")
    
    if [ -z "$raw_nics" ]; then
        echo "错误：未检测到可用业务网卡（请检查网络接口或调整过滤规则）" >&2
        exit 1
    fi

    # 转换为数组并去重
    IFS=$'\n' NIC_LIST=($(echo "$raw_nics" | sort -u))
}

# ==================== 配置执行模块 ====================
configure_ipv6() {
    local nic=$1

    case "$OS_FAMILY" in
        "debian")
            if [ "$USE_NETPLAN" -eq 1 ]; then
                configure_netplan "$nic"
            else
                configure_debian_legacy "$nic"
            fi
            ;;
        "rhel")
            configure_rhel "$nic"
            ;;
        "generic")
            configure_generic "$nic"
            ;;
    esac

    # 统一重启网络服务
    restart_network
}

# Debian家族（Netplan配置）
configure_netplan() {
    local nic=$1
    local netplan_file="/etc/netplan/99-ipv6-$nic.yaml"

    echo "为Netplan环境配置$nic的IPv6..."
    cat <<EOF > "$netplan_file"
network:
  version: 2
  ethernets:
    $nic:
      dhcp6: true
      accept-ra: 2
EOF
    netplan apply
}

# Debian家族（传统interfaces配置）
configure_debian_legacy() {
    local nic=$1
    local config_file="/etc/network/interfaces.d/$nic"

    echo "为传统Debian环境配置$nic的IPv6..."
    [ -f "$config_file" ] && cp "$config_file" "${config_file}.bak"  # 备份原配置
    cat <<EOF > "$config_file"
auto $nic
iface $nic inet6 auto
    accept_ra 2
EOF
}

# RHEL家族配置
configure_rhel() {
    local nic=$1
    local config_file="/etc/sysconfig/network-scripts/ifcfg-$nic"

    echo "为RHEL环境配置$nic的IPv6..."
    [ -f "$config_file" ] && cp "$config_file" "${config_file}.bak"  # 备份原配置
    # 追加/修改IPv6参数（兼容已有配置）
    sed -i '/^IPV6INIT=/d' "$config_file"
    sed -i '/^IPV6_AUTOCONF=/d' "$config_file"
    echo -e "\nIPV6INIT=yes\nIPV6_AUTOCONF=yes\nIPV6_ACCEPT_RA=yes" >> "$config_file"
}

# 通用配置（尝试直接修改sysctl）
configure_generic() {
    local nic=$1

    echo "为未知系统尝试通用IPv6配置..."
    sysctl -w net.ipv6.conf.$nic.autoconf=1 >/dev/null
    sysctl -w net.ipv6.conf.$nic.accept_ra=2 >/dev/null
}

# 重启网络服务
restart_network() {
    echo "正在重启网络服务..."
    if [ "$NM_ACTIVE" -eq 1 ]; then
        systemctl restart NetworkManager
    elif [ "$OS_FAMILY" == "debian" ]; then
        systemctl restart networking
    elif [ "$OS_FAMILY" == "rhel" ]; then
        systemctl restart network
    else
        echo "警告：未知网络服务，建议手动重启网络"
    fi
}

# ==================== 交互主流程 ====================
main() {
    echo "IPv6自动配置脚本（跨平台增强版）"
    echo "----------------------------------------"

    # 系统检测
    detect_system
    echo "检测到系统家族：$OS_FAMILY"
    [ "$USE_NETPLAN" -eq 1 ] && echo "检测到Netplan环境"
    [ "$NM_ACTIVE" -eq 1 ] && echo "NetworkManager正在运行"

    # 网卡检测
    detect_nics
    echo "检测到以下可用网卡（已过滤干扰接口）："
    for i in "${!NIC_LIST[@]}"; do
        # 高亮常见主网卡（eth0/ens3等）
        if [[ "${NIC_LIST[$i]}" =~ ^(eth0|ens[0-9]+)$ ]]; then
            echo "  $((i+1)). ${NIC_LIST[$i]} （推荐：可能为主网卡）"
        else
            echo "  $((i+1)). ${NIC_LIST[$i]}"
        fi
    done

    # 用户选择网卡
    while true; do
        read -p "请输入要配置的网卡序号（1-${#NIC_LIST[@]}）: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#NIC_LIST[@]} ]; then
            local selected_nic="${NIC_LIST[$((choice-1))]}"
            break
        fi
        echo "输入错误，请输入1-${#NIC_LIST[@]}之间的数字" >&2
    done

    # 执行配置
    configure_ipv6 "$selected_nic"

    # 验证提示
    echo -e "\nIPv6配置完成！正在验证..."
    sleep 2  # 等待配置生效
    ip -6 addr show "$selected_nic" | grep -q 'inet6 ' && {
        echo "检测到IPv6地址，配置成功！"
        echo "  示例验证命令：ping6 -c3 2001:4860:4860::8888（Google公共DNS）"
    } || {
        echo "警告：未检测到IPv6地址，可能原因："
        echo "  1. 网络环境不支持IPv6（联系服务商确认）"
        echo "  2. 路由器通告延迟（尝试：ip -6 route show）"
    }
}

main
