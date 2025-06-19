#!/bin/bash
set -euo pipefail

# 检查root权限
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请使用sudo或root权限运行此脚本" >&2
    exit 1
fi

# 系统检测函数（增强虚拟环境适配）
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
        # 识别云厂商优化系统（如阿里云的alinux、腾讯云的tlinux）
        if [[ $ID_LIKE == *"rhel"* ]]; then OS="rhel-like"; fi
        if [[ $ID == "ubuntu" && $VERSION_ID > "19.10" ]]; then USE_NETPLAN=1; fi
    elif type lsb_release >/dev/null 2>&1; then
        OS=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
        VERSION=$(lsb_release -sr)
    else
        OS=$(uname -s | tr '[:upper:]' '[:lower:]')
        VERSION=$(uname -r)
    fi
}

# 获取虚拟服务器可用网卡（兼容ens/eth/enp等虚拟网卡命名）
get_available_nics() {
    echo "检测到以下可用网络接口（已过滤虚拟网桥/容器网卡）："
    ip link show | grep -E '^[0-9]+: (ens|eth|enp|enx)[a-z0-9]+:' | grep -vE 'lo|docker|br-|veth|virbr' | awk -F': ' '{print $2}'
}

# 配置Ubuntu/Debian（兼容netplan）
configure_debian() {
    local nic=$1
    if [ -n "${USE_NETPLAN:-}" ]; then
        # 处理Ubuntu 20.04+的netplan配置
        local netplan_path="/etc/netplan/99-ipv6-$nic.yaml"
        echo "检测到Netplan环境，正在生成$nic的IPv6配置..."
        
        cat <<EOF > "$netplan_path"
network:
  version: 2
  ethernets:
    $nic:
      dhcp6: true
      accept-ra: 2
EOF
        netplan apply
    else
        # 传统interfaces配置
        local config_path="/etc/network/interfaces.d/$nic"
        echo "正在为传统Debian/Ubuntu系统配置$nic的IPv6..."
        
        [ -f "$config_path" ] && cp "$config_path" "$config_path.bak"
        cat <<EOF > "$config_path"
auto $nic
iface $nic inet6 auto
    accept_ra 2
EOF
        systemctl restart networking
    fi
}

# 配置RHEL/CentOS/Fedora（兼容云厂商优化版）
configure_rhel() {
    local nic=$1
    local config_path="/etc/sysconfig/network-scripts/ifcfg-$nic"
    echo "正在为RHEL系系统配置$nic的IPv6..."
    
    [ -f "$config_path" ] && cp "$config_path" "$config_path.bak"
    
    # 追加IPv6配置（兼容虚拟环境自动获取）
    cat <<EOF >> "$config_path"
IPV6INIT=yes
IPV6_AUTOCONF=yes
IPV6_ACCEPT_RA=yes
IPV6_PEERDNS=yes
EOF

    # 优先重启NetworkManager（云服务器常用）
    if systemctl is-active --quiet NetworkManager; then
        systemctl restart NetworkManager
    else
        systemctl restart network
    fi
}

# 主执行流程（增强虚拟环境检测）
main() {
    detect_os
    echo "检测到系统：$OS 版本：$VERSION"
    
    # 获取虚拟服务器可用接口（兼容ens3、eth0等常见虚拟网卡）
    local nics=($(get_available_nics))
    if [ ${#nics[@]} -eq 0 ]; then
        echo "错误：未检测到可用网络接口（可能过滤了虚拟网卡，请检查脚本排除规则）" >&2
        exit 1
    fi
    
    # 显示网卡列表（高亮显示云服务器常见主网卡）
    echo "---------------------------"
    echo "请选择要配置IPv6的网卡（输入序号）："
    for i in "${!nics[@]}"; do
        # 识别云服务器主网卡（常见命名：eth0/ens3/ens192）
        if [[ ${nics[$i]} == "eth0" || ${nics[$i]} == ens[0-9]* ]]; then
            echo -e "$((i+1)). \033[32m${nics[$i]}\033[0m （推荐：可能是主网卡）"
        else
            echo "$((i+1)). ${nics[$i]}"
        fi
    done
    echo "---------------------------"
    
    # 获取用户输入（增强输入验证）
    while true; do
        read -p "请输入选择（1-${#nics[@]}）: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#nics[@]} ]; then
            break
        fi
        echo "错误：请输入1-${#nics[@]}之间的数字" >&2
    done
    local selected_nic=${nics[$((choice-1))]}
    
    # 虚拟环境特殊检查（如OpenStack/KVM的macvtap接口）
    if [[ "$selected_nic" == "tap"* || "$selected_nic" == "vnet"* ]]; then
        echo "警告：检测到可能是虚拟化层接口（$selected_nic），是否继续？(y/n)"
        read -n1 -r confirm
        if [[ ! $confirm =~ ^[Yy]$ ]]; then
            echo "已取消配置" >&2
            exit 1
        fi
    fi
    
    # 执行配置
    case $OS in
        ubuntu|debian)
            configure_debian "$selected_nic"
            ;;
        rhel|centos|fedora|rhel-like)
            configure_rhel "$selected_nic"
            ;;
        *)
            echo "错误：不支持的系统类型 $OS" >&2
            exit 1
            ;;
    esac
    
    echo -e "\nIPv6配置完成！网卡 $selected_nic 已启用自动IPv6配置"
    echo "建议验证："
    echo "  1. 查看IPv6地址：ip -6 addr show $selected_nic"
    echo "  2. 测试连通性：ping6 -c3 2001:4860:4860::8888" # Google公共DNS的IPv6地址
}

main
