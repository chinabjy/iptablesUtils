#!/bin/bash
# 自动维护 iptables 转发规则，支持动态 DDNS 和多端口转发
# 适用系统：CentOS / Ubuntu / Debian 等

# 参数
localport_input=$1
remoteport_input=$2
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
echo "本地端口: $localport_input, 远程端口: $remoteport_input, 目标 DDNS: $remotehost"

# 端口类型判断函数
check_port_type() {
    local port_str="$1"
    # 如果是逗号分隔或多个端口（包含逗号或冒号范围）
    if echo "$port_str" | grep -qE '[,]'; then
        echo "multiport"
    else
        echo "single"
    fi
}

localport_type=$(check_port_type "$localport_input")
remoteport_type=$(check_port_type "$remoteport_input")

# 确保端口类型匹配
if [ "$localport_type" != "$remoteport_type" ]; then
    echo -e "${red}错误：本地端口和远程端口类型不匹配！${black}"
    echo "本地端口类型: $localport_type, 远程端口类型: $remoteport_type"
    exit 1
fi

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
echo "端口类型: $localport_type"
echo "更新 iptables 规则..."

delete_old_rules() {
    echo "删除旧规则..."
    
    # 根据端口类型采用不同的删除策略
    if [ "$localport_type" = "single" ]; then
        # 单端口或连续范围删除逻辑（标准语法）
        echo "删除标准语法规则..."
        
        # 转换端口格式：将可能输入的冒号范围转换为标准语法使用的连字符
        local localport_std=$(echo "$localport_input" | tr ':' '-')
        local remoteport_std=$(echo "$remoteport_input" | tr ':' '-')
        
        # PREROUTING - 匹配标准语法的端口规则（dpt 或 dpts）
        local indices=($(iptables -t nat -L PREROUTING -n --line-number | grep -E "dpts?:$localport_std" | grep "to:$remote:$remoteport_std" | awk '{print $1}' | sort -r))
        for i in "${indices[@]}"; do
            echo "删除 PREROUTING 规则 $i (标准语法)"
            iptables -t nat -D PREROUTING "$i"
        done

        # POSTROUTING - 精确匹配目标IP和端口
        indices=($(iptables -t nat -L POSTROUTING -n --line-number | grep -E "$remote" | grep -E "dpts?:$remoteport_std" | awk '{print $1}' | sort -r))
        for i in "${indices[@]}"; do
            echo "删除 POSTROUTING 规则 $i (标准语法)"
            iptables -t nat -D POSTROUTING "$i"
        done
    else
        # 多端口删除逻辑（使用multiport匹配）
        echo "删除multiport规则..."
        
        # PREROUTING - 使用multiport匹配删除
        local indices=($(iptables -t nat -L PREROUTING -n --line-number | grep "multiport dports $localport_input" | grep "to:$remote:$remoteport_input" | awk '{print $1}' | sort -r))
        for i in "${indices[@]}"; do
            echo "删除 PREROUTING 多端口规则 $i"
            iptables -t nat -D PREROUTING "$i"
        done
        
        # POSTROUTING - 匹配multiport规则
        indices=($(iptables -t nat -L POSTROUTING -n --line-number | grep "$remote" | grep "multiport dports $remoteport_input" | awk '{print $1}' | sort -r))
        for i in "${indices[@]}"; do
            echo "删除 POSTROUTING 多端口规则 $i"
            iptables -t nat -D POSTROUTING "$i"
        done
    fi
}
# 执行删除旧规则
delete_old_rules

# 删除旧规则后，添加新规则的部分应该这样写：
# PREROUTING规则
if [ "$localport_type" = "single" ]; then
    # 单端口或连续范围：使用标准语法
    # 将用户输入的端口范围冒号(:)转换为标准语法认可的连字符(-)
    localport_std=$(echo "$localport_input" | tr ':' '-')
    remoteport_std=$(echo "$remoteport_input" | tr ':' '-')
    
    echo "添加单端口/连续范围转发规则（标准语法）..."
    iptables -t nat -A PREROUTING -p tcp --dport "$localport_std" -j DNAT --to-destination "$remote:$remoteport_std"
    iptables -t nat -A PREROUTING -p udp --dport "$localport_std" -j DNAT --to-destination "$remote:$remoteport_std"
else
    # 多端口列表：使用multiport语法，保持用户输入的冒号格式
    echo "添加多端口转发规则（multiport模块）..."
    iptables -t nat -A PREROUTING -p tcp -m multiport --dports "$localport_input" -j DNAT --to-destination "$remote:$remoteport_input"
    iptables -t nat -A PREROUTING -p udp -m multiport --dports "$localport_input" -j DNAT --to-destination "$remote:$remoteport_input"
fi

# POSTROUTING规则
if [ "$localport_type" = "single" ]; then
    # 单端口或连续范围：使用标准语法
    # 注意POSTROUTING规则中匹配的是远程端口（数据包离开本机去往目标机的端口）
    remoteport_std=$(echo "$remoteport_input" | tr ':' '-')
    
    iptables -t nat -A POSTROUTING -p tcp -d "$remote" --dport "$remoteport_std" -j SNAT --to-source "$local"
    iptables -t nat -A POSTROUTING -p udp -d "$remote" --dport "$remoteport_std" -j SNAT --to-source "$local"
else
    # 多端口列表：使用multiport语法
    iptables -t nat -A POSTROUTING -p tcp -d "$remote" -m multiport --dports "$remoteport_input" -j SNAT --to-source "$local"
    iptables -t nat -A POSTROUTING -p udp -d "$remote" -m multiport --dports "$remoteport_input" -j SNAT --to-source "$local"
fi


echo -e "${green}iptables 转发规则更新完成${black}"
echo "端口类型: $localport_type"
echo "=============================="
