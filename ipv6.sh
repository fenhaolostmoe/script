#!/bin/bash
set -euo pipefail

# ==================== 基础检查 ====================
# 检查root权限
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 错误：请使用sudo或root权限运行此脚本" >&2
    exit 1
fi

# 检查网络工具依赖
if ! command -v ip &>/dev/null; then
    echo "❌ 错误：系统缺少ip命令（请安装iproute2：apt install iproute2 或 yum install iproute2）" >&2
    exit 1
fi

# ==================== 核心功能函数 ====================
detect_system() {
    # 初始化系统家族
    OS_FAMILY="unknown"
    USE_NETPLAN=0
    NM_ACTIVE=0

    # 读取系统信息（安全处理未定义字段）
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-}"
        OS_VERSION="${VERSION_ID:-0}"
        OS_ID_LIKE="${ID_LIKE:-}"
    fi

    # 判断系统家族（Debian/RHEL/通用）
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

    # 检测Netplan（仅Debian家族，数值化版本比较）
    if [[ "$OS_FAMILY" == "debian" && -d /etc/netplan ]]; then
        # 将版本号转换为数值（如20.04 → 2004，19.10 → 1910）
        local version_num=$(echo "$OS_VERSION" | tr -d '.' | awk '{printf "%04d", $0}')
        if [ "$version_num" -gt 1910 ]; then  # 大于19.10（即20.04+）
            USE_NETPLAN=1
        fi
    fi

    # 检测NetworkManager状态（忽略错误输出）
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        NM_ACTIVE=1
    fi
}

detect_main_nic() {
    # 优先通过默认路由识别主网卡（最可靠）
    local main_nic=$(ip route show default | awk '/default/ {print $5}' | head -n1)
    
    # 若未找到默认路由（如内网环境）， fallback到常见主网卡命名
    if [ -z "$main_nic" ]; then
        local common_nics=("eth0" "ens3" "ens192" "enp0s3")  # 云服务器常见主网卡名
        for nic in "${common_nics[@]}"; do
            if ip link show "$nic" &>/dev/null; then
                main_nic="$nic"
                break
            fi
        done
    fi

    # 最终验证：确保网卡存在
    if [ -z "$main_nic" ] || ! ip link show "$main_nic" &>/dev/null; then
        echo "❌ 错误：无法识别主网卡，请手动指定（示例：sudo ./script.sh eth0）" >&2
        exit 1
    fi

    echo "$main_nic"
}

# 交互确认函数（支持非交互式环境）
confirm() {
    local prompt="$1"
    local default="${2:-Y}"  # 默认Y（非交互时自动确认）
    local response

    # 非交互式环境直接使用默认值
    if [ ! -t 0 ]; then
        return 0  # 默认确认
    fi

    # 交互式环境等待用户输入
    while true; do
        read -p "$prompt [${default^^}/${default,,}] " response
        response="${response:-$default}"  # 无输入时使用默认
        case "$response" in
            [Yy]*) return 0 ;;  # 确认
            [Nn]*) return 1 ;;  # 取消
            *) echo "输入无效，请输入 Y 或 N" ;;
        esac
    done
}

configure_ipv6() {
    local nic=$1
    case "$OS_FAMILY" in
        "debian")
            if [ "$USE_NETPLAN" -eq 1 ]; then
                # Netplan配置（合并模式，避免覆盖原有配置）
                local netplan_file="/etc/netplan/99-ipv6-$nic.yaml"
                echo "ℹ️ 为Netplan环境配置网卡 $nic 的IPv6（合并模式）"
                
                # 备份原文件（若存在）
                [ -f "$netplan_file" ] && cp "$netplan_file" "${netplan_file}.bak"
                
                # 生成/合并配置（使用yq工具，若不存在则覆盖）
                if command -v yq &>/dev/null; then
                    yq eval ".network.ethernets[\"$nic\"].dhcp6 = true | .network.ethernets[\"$nic\"].accept-ra = 2" -i "$netplan_file"
                else
                    echo "⚠️ 未检测到yq工具，将覆盖生成新配置文件（原文件已备份）"
                    cat > "$netplan_file" <<EOF
network:
  version: 2
  ethernets:
    $nic:
      dhcp6: true
      accept-ra: 2
EOF
                fi
                
                # 应用配置并检查错误
                if ! netplan apply; then
                    echo "❌ Netplan应用失败，尝试回滚..."
                    [ -f "${netplan_file}.bak" ] && mv "${netplan_file}.bak" "$netplan_file" && netplan apply
                    exit 1
                fi
            else
                # 传统interfaces配置（备份原文件）
                local config_file="/etc/network/interfaces.d/$nic"
                echo "ℹ️ 为传统Debian环境配置网卡 $nic 的IPv6"
                [ -f "$config_file" ] && cp "$config_file" "${config_file}.bak"
                cat > "$config_file" <<EOF
auto $nic
iface $nic inet6 auto
    accept_ra 2
EOF
                # 重启网络并检查错误
                if ! systemctl restart networking; then
                    echo "❌ 网络服务重启失败，尝试回滚..."
                    [ -f "${config_file}.bak" ] && mv "${config_file}.bak" "$config_file" && systemctl restart networking
                    exit 1
                fi
            fi
            ;;
        "rhel")
            # RHEL系配置（避免重复参数）
            local config_file="/etc/sysconfig/network-scripts/ifcfg-$nic"
            echo "ℹ️ 为RHEL环境配置网卡 $nic 的IPv6"
            
            # 备份原文件
            [ -f "$config_file" ] && cp "$config_file" "${config_file}.bak"
            
            # 仅追加不存在的参数
            if ! grep -q '^IPV6INIT=' "$config_file"; then
                echo "IPV6INIT=yes" >> "$config_file"
            fi
            if ! grep -q '^IPV6_AUTOCONF=' "$config_file"; then
                echo "IPV6_AUTOCONF=yes" >> "$config_file"
            fi
            if ! grep -q '^IPV6_ACCEPT_RA=' "$config_file"; then
                echo "IPV6_ACCEPT_RA=yes" >> "$config_file"
            fi
            
            # 重启网络服务并检查错误
            local service="network"
            [ "$NM_ACTIVE" -eq 1 ] && service="NetworkManager"
            if ! systemctl restart "$service"; then
                echo "❌ $service 重启失败，尝试回滚..."
                [ -f "${config_file}.bak" ] && mv "${config_file}.bak" "$config_file" && systemctl restart "$service"
                exit 1
            fi
            ;;
        "generic")
            # 通用系统（内核参数+持久化）
            echo "ℹ️ 为未知系统配置网卡 $nic 的IPv6"
            sysctl -w net.ipv6.conf.$nic.autoconf=1 >/dev/null
            sysctl -w net.ipv6.conf.$nic.accept_ra=2 >/dev/null
            # 持久化配置（覆盖原文件，避免重复）
            echo "net.ipv6.conf.$nic.autoconf=1" > /etc/sysctl.d/99-ipv6-$nic.conf
            echo "net.ipv6.conf.$nic.accept_ra=2" >> /etc/sysctl.d/99-ipv6-$nic.conf
            sysctl --system  # 立即生效
            ;;
    esac
}

# ==================== 主流程 ====================
main() {
    echo "🌐 IPv6智能配置脚本（完美修复版）"
    echo "----------------------------------------"

    # 系统检测
    detect_system
    echo "ℹ️ 检测到系统家族：$OS_FAMILY"
    [ "$USE_NETPLAN" -eq 1 ] && echo "ℹ️ 检测到Netplan环境（版本≥20.04）"
    [ "$NM_ACTIVE" -eq 1 ] && echo "ℹ️ NetworkManager正在运行"

    # 自动识别主网卡（支持手动指定）
    local main_nic=${1:-$(detect_main_nic)}  # 允许通过参数手动指定网卡（如sudo ./script.sh eth1）
    echo "ℹ️ 目标网卡：$main_nic"

    # 交互确认主网卡（非交互自动确认）
    if ! confirm "是否使用此网卡进行配置？"; then
        echo "❌ 用户取消配置，脚本退出"
        exit 1
    fi

    # 交互确认开始配置（非交互自动确认）
    echo -e "\nℹ️ 即将执行以下操作："
    case "$OS_FAMILY" in
        "debian") [ "$USE_NETPLAN" -eq 1 ] && action="合并Netplan配置并应用" || action="修改传统网络接口文件（已备份）" ;;
        "rhel") action="追加IPv6参数到网卡配置文件（避免重复）" ;;
        "generic") action="调整IPv6内核参数并持久化" ;;
    esac
    echo "  - $action"
    if ! confirm "确认开始配置？"; then
        echo "❌ 用户取消配置，脚本退出"
        exit 1
    fi

    # 执行配置
    configure_ipv6 "$main_nic"
    echo -e "\n✅ IPv6配置完成！正在验证（最多等待10秒）..."

    # 智能验证（循环检测，最多等待10秒）
    local timeout=10
    local start_time=$(date +%s)
    while true; do
        if ip -6 addr show "$main_nic" | grep -q 'inet6 '; then
            echo "✔️ 成功获取IPv6地址！"
            echo "  验证命令：ping6 -c3 2001:4860:4860::8888（Google公共DNS）"
            break
        fi

        local current_time=$(date +%s)
        if [ $((current_time - start_time)) -ge $timeout ]; then
            echo "⚠️ 超时未检测到IPv6地址，可能原因："
            echo "  1. 网络环境不支持IPv6（联系服务商确认）"
            echo "  2. 路由器通告延迟（尝试：ip -6 route show）"
            break
        fi

        sleep 1
    done
}

# 支持通过参数手动指定网卡（如sudo ./script.sh eth1）
main "${1:-}"
