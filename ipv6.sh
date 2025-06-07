#!/bin/bash  
# 极简IPv6网关配置脚本 - 仅设置fe80::1为默认网关  

# 检测网卡（优先eth0）  
INTERFACE=$(ip addr | grep -E 'eth|ens|enp' | grep -v lo | head -1 | awk '{print $2}' | cut -d: -f1 || echo "eth0")  

echo "正在设置IPv6网关: fe80::1%$INTERFACE"  
ip -6 route add default via fe80::1 dev $INTERFACE metric 1  

# 持久化配置（按系统类型）  
if [[ $(uname -s) == "Linux" ]]; then  
  OS_TYPE=$(cat /etc/os-release 2>/dev/null | grep ^NAME | cut -d\" -f2 | tr '[:upper:]' '[:lower:]' || uname -s)  
  
  case $OS_TYPE in  
    *centos*|*rhel*|*fedora*)  
      echo "IPV6_DEFAULTGW=fe80::1%$INTERFACE" >> /etc/sysconfig/network-scripts/ifcfg-$INTERFACE  
      systemctl restart network || service network restart  
      echo "CentOS系配置已保存"  
      ;;  
    *ubuntu*|*debian*)  
      sed -i "/gateway6/d" /etc/netplan/*.yaml 2>/dev/null  
      echo "      gateway6: fe80::1" >> /etc/netplan/01-netcfg.yaml  
      netplan apply  
      echo "Ubuntu系配置已保存"  
      ;;  
    *)  
      echo "ip -6 route add default via fe80::1 dev $INTERFACE metric 1" >> /etc/rc.local  
      chmod +x /etc/rc.local  
      echo "已写入rc.local，重启后生效"  
      ;;  
  esac  
fi  
