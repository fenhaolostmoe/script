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

# ==================== 核心功能函数 ====================
detect_system() {
    OS_FAMILY="unknown"
    USE_NETPLAN=0
    NM_ACTIVE=0

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-}"
        OS_VERSION="${VERSION_ID:-0}"
        OS_ID_LIKE="${ID_LIKE:-}"
    fi

    case "$OS_ID" in
        ubuntu|debian) OS_FAMILY="debian" ;;
        rhel|centos|fedora|almalinux|rocky) OS_FAMILY="rhel" ;;
        *)
            if [[ "$OS_ID_LIKE" == *"rhel"* ]]; then OS_FAMILY="rhel"
            elif [[ "$OS_ID_LIKE" == *"debian"* ]]; then OS_FAMILY="debian"
            else OS_FAMILY="generic"
            fi
            ;;
    esac

    if [[ "$OS_FAMILY" == "debian" && -d /etc/netplan ]]; then
        local version_num=$(echo "$OS_VERSION" | tr -d '.' | awk '{printf "%04d", $0}')
        if [ "$version_num" -gt 1910 ]; then
            USE_NETPLAN=1
        fi
    fi

    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        NM_ACTIVE=1
    fi
}

detect_main_nic() {
    local main_nic=$(ip route show default | awk '/default/ {print $5}' | head -n1)
    
    if [ -z "$main_nic" ]; then
        local common_nics=("eth0" "ens3" "ens192" "enp0s3")
        for nic in "${common_nics[@]}"; do
            if ip link show "$nic" &>/dev/null; then
                main_nic="$nic"
                break
            fi
        done
    fi

    if [ -z "$main_nic" ] || ! ip link show "$main_nic" &>/dev/null; then
        echo "错误：无法识别主网卡，请手动指定（示例：sudo ./script.sh eth0）" >&2
        exit 1
    fi

    echo "$main_nic"
}

confirm() {
    local prompt="$1"
    local default="${2:-Y}"
    local response

    if [ ! -t 0 ]; then
        return 0
    fi

    while true; do
        read -p "$prompt [${default^^}/${default,,}] " response
        response="${response:-$default}"
        case "$response" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) echo "输入无效，请输入 Y 或 N" ;;
        esac
    done
}

# 获取当前IPv6网关
get_ipv6_gateway() {
    local nic=$1
    ip -6 route show default via dev "$nic" 2>/dev/null | awk '/default/ {print $3}'
}

# 设置IPv6网关为fe80::1
set_ipv6_gateway() {
    local nic=$1
    local current_gateway=$(get_ipv6_gateway "$nic")
    local new_gateway="fe80::1"
    
    if [ -n "$current_gateway" ]; then
        if [ "$current_gateway" != "$new_gateway" ]; then
            echo "检测到错误网关: $current_gateway，正在修改为 $new_gateway"
            # 删除当前网关
            ip -6 route del default via "$current_gateway" dev "$nic" || true
        else
            echo "网关已正确配置为 $new_gateway"
            return 0
        fi
    else
        echo "未检测到IPv6网关，正在设置为 $new_gateway"
    fi
    
    # 添加新网关
    ip -6 route add default via "$new_gateway" dev "$nic"
    
    if [ $? -eq 0 ]; then
        echo "IPv6网关已成功设置为 $new_gateway"
        return 0
    else
        echo "设置IPv6网关失败"
        return 1
    fi
}

# 配置IPv6自动获取
configure_ipv6() {
    local nic=$1
    case "$OS_FAMILY" in
        "debian")
            if [ "$USE_NETPLAN" -eq 1 ]; then
                local netplan_file="/etc/netplan/99-ipv6-$nic.yaml"
                echo "为Netplan环境配置网卡 $nic 的IPv6（合并模式）"
                
                [ -f "$netplan_file" ] && cp "$netplan_file" "${netplan_file}.bak"
                
                if command -v yq &>/dev/null; then
                    yq eval ".network.ethernets[\"$nic\"].dhcp6 = true | .network.ethernets[\"$nic\"].accept-ra = 2" -i "$netplan_file"
                else
                    echo "未检测到yq工具，将覆盖生成新配置文件（原文件已备份）"
                    cat > "$netplan_file" <<EOF
network:
  version: 2
  ethernets:
    $nic:
      dhcp6: true
      accept-ra: 2
EOF
                fi
                
                if ! netplan apply; then
                    echo "Netplan应用失败，尝试回滚..."
                    [ -f "${netplan_file}.bak" ] && mv "${netplan_file}.bak" "$netplan_file" && netplan apply
                    exit 1
                fi
            else
                local config_file="/etc/network/interfaces.d/$nic"
                echo "为传统Debian环境配置网卡 $nic 的IPv6"
                [ -f "$config_file" ] && cp "$config_file" "${config_file}.bak"
                cat > "$config_file" <<EOF
auto $nic
iface $nic inet6 auto
    accept_ra 2
EOF
                if ! systemctl restart networking; then
                    echo "网络服务重启失败，尝试回滚..."
                    [ -f "${config_file}.bak" ] && mv "${config_file}.bak" "$config_file" && systemctl restart networking
                    exit 1
                fi
            fi
            ;;
        "rhel")
            local config_file="/etc/sysconfig/network-scripts/ifcfg-$nic"
            echo "为RHEL环境配置网卡 $nic 的IPv6"
            
            [ -f "$config_file" ] && cp "$config_file" "${config_file}.bak"
            
            if ! grep -q '^IPV6INIT=' "$config_file"; then
                echo "IPV6INIT=yes" >> "$config_file"
            fi
            if ! grep -q '^IPV6_AUTOCONF=' "$config_file"; then
                echo "IPV6_AUTOCONF=yes" >> "$config_file"
            fi
            if ! grep -q '^IPV6_ACCEPT_RA=' "$config_file"; then
                echo "IPV6_ACCEPT_RA=yes" >> "$config_file"
            fi
            
            local service="network"
            [ "$NM_ACTIVE" -eq 1 ] && service="NetworkManager"
            if ! systemctl restart "$service"; then
                echo "$service 重启失败，尝试回滚..."
                [ -f "${config_file}.bak" ] && mv "${config_file}.bak" "$config_file" && systemctl restart "$service"
                exit 1
            fi
            ;;
        "generic")
            echo "为未知系统配置网卡 $nic 的IPv6"
            sysctl -w net.ipv6.conf.$nic.autoconf=1 >/dev/null
            sysctl -w net.ipv6.conf.$nic.accept_ra=2 >/dev/null
            echo "net.ipv6.conf.$nic.autoconf=1" > /etc/sysctl.d/99-ipv6-$nic.conf
            echo "net.ipv6.conf.$nic.accept_ra=2" >> /etc/sysctl.d/99-ipv6-$nic.conf
            sysctl --system
            ;;
    esac
    
    # 设置IPv6网关
    set_ipv6_gateway "$nic"
}

# 验证IPv6连接
verify_ipv6_connection() {
    local nic=$1
    echo -e "\n正在验证IPv6连接（最多等待15秒）..."
    
    # 检查是否有全局IPv6地址
    local timeout=15
    local start_time=$(date +%s)
    local global_ipv6=""
    
    while true; do
        global_ipv6=$(ip -6 addr show "$nic" scope global | grep 'inet6' | awk '{print $2}' | cut -d/ -f1 | head -n1)
        if [ -n "$global_ipv6" ]; then
            echo "已获取全局IPv6地址: $global_ipv6"
            break
        fi
        
        local current_time=$(date +%s)
        if [ $((current_time - start_time)) -ge $timeout ]; then
            echo "超时未获取到全局IPv6地址"
            break
        fi
        
        sleep 1
    done
    
    # 检查网关是否正确配置
    local gateway=$(get_ipv6_gateway "$nic")
    if [ "$gateway" == "fe80::1" ]; then
        echo "IPv6网关配置正确: $gateway"
    else
        echo "警告: IPv6网关配置可能不正确: $gateway"
    fi
    
    # 尝试ping6测试连接
    echo "尝试ping6测试连接..."
    if ping6 -c3 -I "$nic" 2001:4860:4860::8888 &>/dev/null; then
        echo "IPv6连接测试成功！"
        echo "  验证命令：ping6 -c3 2001:4860:4860::8888（Google公共DNS）"
    else
        echo "IPv6连接测试失败，可能原因："
        echo "  1. 网络环境不支持IPv6（联系服务商确认）"
        echo "  2. 路由器通告延迟或配置错误"
        echo "  3. 防火墙阻止了IPv6流量"
    fi
}

main() {
    echo "IPv6智能配置脚本（带网关修复功能）"
    echo "----------------------------------------"

    detect_system
    echo "检测到系统家族：$OS_FAMILY"
    [ "$USE_NETPLAN" -eq 1 ] && echo "检测到Netplan环境（版本≥20.04）"
    [ "$NM_ACTIVE" -eq 1 ] && echo "NetworkManager正在运行"

    local main_nic=${1:-$(detect_main_nic)}
    echo "目标网卡：$main_nic"

    if ! confirm "是否使用此网卡进行配置？"; then
        echo "用户取消配置，脚本退出"
        exit 1
    fi

    echo -e "\n即将执行以下操作："
    case "$OS_FAMILY" in
        "debian") [ "$USE_NETPLAN" -eq 1 ] && action="合并Netplan配置并应用" || action="修改传统网络接口文件（已备份）" ;;
        "rhel") action="追加IPv6参数到网卡配置文件（避免重复）" ;;
        "generic") action="调整IPv6内核参数并持久化" ;;
    esac
    echo "  - $action"
    echo "  - 检测并修复IPv6网关配置（设置为fe80::1）"
    if ! confirm "确认开始配置？"; then
        echo "用户取消配置，脚本退出"
        exit 1
    fi

    configure_ipv6 "$main_nic"
    verify_ipv6_connection "$main_nic"
    
    echo -e "\nIPv6配置完成！"
    echo "注意：如果网关设置未生效，可能需要重启网络服务或系统。"
}

main "${1:-}"
