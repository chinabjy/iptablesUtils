#!/bin/bash
# 自动维护 iptables 转发规则，支持动态 DDNS
# 适用系统：CentOS / Ubuntu / Debian 等



# 参数
localport=$1
remoteport=$2
remotehost=$3
tempFile=$4
local=$5
force_add=$6  # 用于标记是否绕过 IP 检查

[ -z "$tempFile" ] && tempFile=remoteip

# 颜色
red="\033[31m"
green="\033[32m"
black="\033[0m"

# 检查 root
if [ "$EUID" -ne 0 ]; then
    echo -e "${red}请使用 root 用户执行本脚本！${black}"
    exit 1
fi

if [ -z "$remotehost" ]; then
    echo -e "${red}Usage: $0 localport remoteport remotehost [tempFile]${black}"
    exit 1
fi

echo "=============================="
echo "时间: $(date)"
echo "本地端口: $localport, 远程端口: $remoteport, 目标 DDNS: $remotehost"

# 确保 IP 转发开启
check_sysctl() {
    if ! command -v sysctl >/dev/null 2>&1; then
        echo -e "${red}未找到 sysctl 命令，正在安装...${black}"
        if command -v yum >/dev/null 2>&1; then
            yum install -y procps-ng
        elif command -v apt >/dev/null 2>&1; then
            apt-get install -y procps
        else
            echo -e "${red}不支持的包管理器，无法安装 sysctl。请手动安装 procps 或 procps-ng 包。${black}"
            exit 1
        fi
    fi
    # 确保 IP 转发开启
    if ! sysctl net.ipv4.ip_forward | grep -q "1"; then
        echo "开启 IP 转发..."
        sysctl -w net.ipv4.ip_forward=1
        grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
    fi
}

# 调用检查 sysctl 和 IP 转发
check_sysctl

# 解析 DDNS 域名
remote=$(getent hosts "$remotehost" | awk '{print $1}' | head -n1)
if [ -z "$remote" ]; then
    echo -e "${red}无法解析 $remotehost，请检查域名！${black}"
    exit 1
fi

# 如果是绕过 IP 检查（force_add），不检查 IP 是否变化
if [ "$force_add" != "force_add" ]; then
    # 暂停范围：0~10 秒，避免多个脚本冲突
    sleep "$(awk 'BEGIN{srand(); printf "%.3f", rand()*10}')"
    # 检查 IP 是否变化
    lastremote=$(cat /root/$tempFile 2>/dev/null)
    if [ "$lastremote" = "$remote" ]; then
        echo "地址未变化，退出"
        exit 0
    fi

    echo "last remote IP: $lastremote"
    echo "new remote IP: $remote"
    echo "$remote" > /root/$tempFile
fi

# 获取本机 IP，如果传递了 local 参数，使用传递的值
if [ -z "$local" ]; then
    local=$(ip -o -4 addr list | grep -Ev '\s(docker|lo)' | awk '{print $4}' | cut -d/ -f1 | grep -Ev '(^127\.|^10\.|^172\.1[6-9]|^172\.2[0-9]|^172\.3[0-1]|^192\.168\.)')
    [ -z "$local" ] && local=$(ip -o -4 addr list | grep -Ev '\s(docker|lo)' | awk '{print $4}' | cut -d/ -f1)
fi
echo "本机 IP: $local"
echo "更新 iptables 规则..."

# 删除旧规则
delete_old_rules() {
    # PREROUTING
    local indices=($(iptables -t nat -L PREROUTING -n --line-number | grep "dpt:$localport" | awk '{print $1}' | sort -r))
    for i in "${indices[@]}"; do
        echo "删除 PREROUTING 规则 $i"
        iptables -t nat -D PREROUTING "$i"
    done

    # POSTROUTING
    indices=($(iptables -t nat -L POSTROUTING -n --line-number | grep "$remote" | grep "$remoteport" | awk '{print $1}' | sort -r))
    for i in "${indices[@]}"; do
        echo "删除 POSTROUTING 规则 $i"
        iptables -t nat -D POSTROUTING "$i"
    done
}

# 添加新规则
iptables -t nat -A PREROUTING -p tcp --dport "$localport" -j DNAT --to-destination "$remote:$remoteport"
iptables -t nat -A PREROUTING -p udp --dport "$localport" -j DNAT --to-destination "$remote:$remoteport"
iptables -t nat -A POSTROUTING -p tcp -d "$remote" --dport "$remoteport" -j SNAT --to-source "$local"
iptables -t nat -A POSTROUTING -p udp -d "$remote" --dport "$remoteport" -j SNAT --to-source "$local"

echo -e "${green}iptables 转发规则更新完成${black}"
echo "=============================="
