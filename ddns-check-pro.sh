#!/bin/bash

# 参数定义
localport=$1  # 中转端口
remoteport=$2  # 中转端口
remotehost=$3  # 中转目标host
tempFile=$4
local=$5
allowed_source=$6  # 允许的源IP网段

if [ "$4" = "" ]; then
    tempFile=remoteip
fi

red="\033[31m"
black="\033[0m"

# 权限检查
if [ $USER != "root" ]; then
    echo -e "${red}请使用root用户执行本脚本!! ${black}"
    exit 1
fi

if [ "$remotehost" = "" ]; then
    echo -e "${red}Usage: bash iptables4ddns.sh localport remoteport remotehost [ remoteIpTempflie ]; ${black}"
    exit 1
fi

echo ""
echo "时间：$(date)"

# 封装的iptables命令，避免重复添加[8](@ref)
iptables_no_dup() {
    local cmd="$@"
    local check_cmd=$(echo "$cmd" | sed -e 's/-A/-C/g' -e 's/-I/-C/g')
    
    # 先检查规则是否存在[7](@ref)
    if ! eval "iptables $check_cmd" >/dev/null 2>&1; then
        echo "执行: iptables $cmd"
        eval "iptables $cmd"
        return $?
    else
        echo "规则已存在，跳过: iptables $cmd"
        return 0
    fi
}

# 精确删除旧规则函数
delete_old_rules() {
    local localport=$1
    local remote=$2
    local remoteport=$3
    local allowed_source=$4
    
    echo "开始删除旧规则: 端口 $localport->$remoteport, 目标 $remote, 源 $allowed_source"
    
    # 删除PREROUTING规则 - 使用更精确的匹配[6](@ref)
    for proto in tcp udp; do
        while true; do
            # 使用iptables-save进行精确匹配[7](@ref)
            rule_match=$(iptables-save -t nat | grep -E "PREROUTING.*-s $allowed_source.*-p $proto.*--dport $localport.*DNAT.*to:$remote:$remoteport")
            if [ -n "$rule_match" ]; then
                echo "删除PREROUTING规则: $rule_match"
                # 使用精确的删除命令
                iptables -t nat -D PREROUTING -s $allowed_source -p $proto --dport $localport -j DNAT --to-destination $remote:$remoteport
            else
                break
            fi
        done
    done
    
    # 删除POSTROUTING规则
    for proto in tcp udp; do
        while true; do
            rule_match=$(iptables-save -t nat | grep -E "POSTROUTING.*-d $remote.*-p $proto.*--dport $remoteport.*SNAT.*to:$local")
            if [ -n "$rule_match" ]; then
                echo "删除POSTROUTING规则: $rule_match"
                iptables -t nat -D POSTROUTING -p $proto -d $remote --dport $remoteport -j SNAT --to-source $local
            else
                break
            fi
        done
    done
}

# 开启端口转发
sed -n '/^net.ipv4.ip_forward=1/'p /etc/sysctl.conf | grep -q "net.ipv4.ip_forward=1"
if [ $? -ne 0 ]; then
    echo -e "net.ipv4.ip_forward=1" >> /etc/sysctl.conf && sysctl -p
fi

# 解析域名获取IP地址
if [ "$(echo $remotehost | grep -E -o '([0-9]{1,3}[\.]){3}[0-9]{1,3}')" != "" ]; then
    isip=true
    remote=$remotehost
    echo -e "${red}警告：你输入的目标地址是一个ip!${black}"
    echo -e "${red}该脚本的目标是，使用iptables中转到动态ip的vps${black}"
    echo -e "${red}所以remotehost参数应该是动态ip的vps的ddns域名${black}"
    exit 1
else
    remote=$(host -t a $remotehost | grep -E -o "([0-9]{1,3}[\.]){3}[0-9]{1,3}" | head -1)
    if [ "$remote" = "" ]; then
        echo -e "${red}无法解析remotehost，请填写正确的remotehost！${black}"
        exit 1
    fi
fi

# 开放FORWARD链
arr1=(`iptables -L FORWARD -n --line-number | grep "REJECT" | grep "0.0.0.0/0" | sort -r | awk '{print $1,$2,$5}' | tr " " ":" | tr "\n" " "`)
for cell in ${arr1[@]}
do
    arr2=(`echo $cell | tr ":" " "`)
    index=${arr2[0]}
    echo "删除禁止FOWARD的规则——$index"
    iptables -D FORWARD $index
done
iptables --policy FORWARD ACCEPT

# 检查IP是否变化
lastremote=$(cat /root/$tempFile 2> /dev/null)
if [ "$lastremote" = "$remote" ]; then
    echo "地址解析未变化，退出"
    exit 1
fi

echo "last-remote-ip: $lastremote"
echo "new-remote-ip: $remote"
echo $remote > /root/$tempFile

echo "local-ip: $local"
echo "重新设置iptables转发"

# 删除旧的中转规则
delete_old_rules $localport $remote $remoteport $allowed_source

# 建立新的中转规则
echo "$(date) - 建立新的中转规则，仅允许来源IP: $allowed_source"
iptables_no_dup -t nat -A PREROUTING -s $allowed_source -p tcp --dport $localport -j DNAT --to-destination $remote:$remoteport
iptables_no_dup -t nat -A PREROUTING -s $allowed_source -p udp --dport $localport -j DNAT --to-destination $remote:$remoteport
iptables_no_dup -t nat -A POSTROUTING -p tcp -d $remote --dport $remoteport -j SNAT --to-source $local
iptables_no_dup -t nat -A POSTROUTING -p udp -d $remote --dport $remoteport -j SNAT --to-source $local

# 验证规则是否添加成功
echo "验证新规则:"
iptables -t nat -L PREROUTING -n | grep -E "$localport.*$remote:$remoteport" && echo "PREROUTING规则添加成功" || echo "PREROUTING规则添加失败"
iptables -t nat -L POSTROUTING -n | grep -E "$remote.*$remoteport" && echo "POSTROUTING规则添加成功" || echo "POSTROUTING规则添加失败"

echo "iptables转发规则更新完成"
