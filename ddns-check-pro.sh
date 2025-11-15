#! /bin/bash
# rm -f iptables4ddns.sh;wget  https://raw.githubusercontent.com/arloor/iptablesUtils/master/iptables4ddns.sh;bash iptables4ddns.sh $localport $remoteport $remotehost [ $remoteIpTempfile——暂存ddns的目标ip,用于定时任务判断时候需要更新iptables转发 ];



localport=$1  #中转端口，自行修改
remoteport=$2  #中转端口，自行修改
remotehost=$3 #中转目标host，自行修改
tempFile=$4
local=$5
# === 新增：第6个参数，允许的源IP网段 ===
allowed_source=$6

if [ "$4" = "" ];then
    tempFile=remoteip
fi



red="\033[31m"
black="\033[0m"

if [ $USER != "root" ];then
    echo   -e "${red}请使用root用户执行本脚本!! ${black}"
    exit 1
fi

if [ "$remotehost" = "" ];then
    echo -e "${red}Usage: bash iptables4ddns.sh localport remoteport remotehost [ remoteIpTempflie ]; ${black}"
    exit 1
fi


echo ""
echo 时间：$(date)

# 开启端口转发
sed -n '/^net.ipv4.ip_forward=1/'p /etc/sysctl.conf | grep -q "net.ipv4.ip_forward=1"
if [ $? -ne 0 ]; then
    echo -e "net.ipv4.ip_forward=1" >> /etc/sysctl.conf && sysctl -p
fi

if [ "$(echo  $remotehost |grep -E -o '([0-9]{1,3}[\.]){3}[0-9]{1,3}')" != "" ];then
    isip=true
    remote=$remotehost

    echo -e "${red}警告：你输入的目标地址是一个ip!${black}"
    echo -e "${red}该脚本的目标是，使用iptables中转到动态ip的vps${black}"
    echo -e "${red}所以remotehost参数应该是动态ip的vps的ddns域名${black}"
    exit 1
else
    remote=$(host -t a  $remotehost|grep -E -o "([0-9]{1,3}[\.]){3}[0-9]{1,3}"|head -1)
    if [ "$remote" = "" ];then
        echo -e "${red}无法解析remotehost，请填写正确的remotehost！${black}"
        exit 1
    fi
fi

#开放FORWARD链
arr1=(`iptables -L FORWARD -n  --line-number |grep "REJECT"|grep "0.0.0.0/0"|sort -r|awk '{print $1,$2,$5}'|tr " " ":"|tr "\n" " "`)  #16:REJECT:0.0.0.0/0 15:REJECT:0.0.0.0/0
for cell in ${arr1[@]}
do
    arr2=(`echo $cell|tr ":" " "`)  #arr2=16 REJECT 0.0.0.0/0
    index=${arr2[0]}
    echo 删除禁止FOWARD的规则——$index
    iptables -D FORWARD $index
done
iptables --policy FORWARD ACCEPT

lastremote=$(cat /root/$tempFile 2> /dev/null)
if [ "$lastremote" = "$remote" ]; then
    echo 地址解析未变化，退出
    exit 1
fi

echo last-remote-ip: $lastremote
echo new-remote-ip: $remote
echo $remote > /root/$tempFile


## 获取本机地址
#local=$(ip -o -4 addr list | grep -Ev '\s(docker|lo)' | awk '{print $4}' | cut -d/ -f1 | grep -Ev '(^127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$)|(^10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$)|(^172\.1[6-9]{1}[0-9]{0,1}\.[0-9]{1,3}\.[0-9]{1,3}$)|(^172\.2[0-9]{1}[0-9]{0,1}\.[0-9]{1,3}\.[0-9]{1,3}$)|(^172\.3[0-1]{1}[0-9]{0,1}\.[0-9]{1,3}\.[0-9]{1,3}$)|(^192\.168\.[0-9]{1,3}\.[0-9]{1,3}$)')
#if [ "${local}" = "" ]; then
#	local=$(ip -o -4 addr list | grep -Ev '\s(docker|lo)' | awk '{print $4}' | cut -d/ -f1 )
#fi

echo  local-ip: $local
echo  重新设置iptables转发

#删除旧的中转规则
# 在原有的删除规则循环中，加入-s $allowed_source匹配，确保只删除属于该白名单的旧规则
#arr1=(`iptables -L PREROUTING -n -t nat --line-number |grep DNAT |grep "dpt:$localport " |grep "src $allowed_source" |sort -r|awk '{print $1,$3,$9}'|tr " " ":"|tr "\n" " "`)

# 在脚本主逻辑中替换原有的删除和添加规则部分

# 删除旧规则
delete_old_rules $localport $remote $remoteport $allowed_source

# 添加新规则（使用封装函数）
echo "$(date) - 建立新的中转规则，仅允许来源IP: $allowed_source"
iptables_no_dup -t nat -A PREROUTING -s $allowed_source -p tcp --dport $localport -j DNAT --to-destination $remote:$remoteport
iptables_no_dup -t nat -A PREROUTING -s $allowed_source -p udp --dport $localport -j DNAT --to-destination $remote:$remoteport
iptables_no_dup -t nat -A POSTROUTING -p tcp -d $remote --dport $remoteport -j SNAT --to-source $local
iptables_no_dup -t nat -A POSTROUTING -p udp -d $remote --dport $remoteport -j SNAT --to-source $local

# 更精确的删除旧规则函数
delete_old_rules() {
    local localport=$1
    local remote=$2
    local remoteport=$3
    local allowed_source=$4
    
    # 删除PREROUTING规则（分别处理TCP和UDP）
    for proto in tcp udp; do
        while true; do
            # 使用更精确的匹配条件
            rule_num=$(iptables -t nat -L PREROUTING -n --line-numbers | \
                awk -v port="$localport" -v src="$allowed_source" -v rmt="$remote" -v rmt_port="$remoteport" -v p="$proto" \
                '$0 ~ p && $0 ~ "dpt:" port " " && $0 ~ "to:" rmt ":" rmt_port && $0 ~ src {print $1; exit}')
            
            if [ -n "$rule_num" ]; then
                echo "删除PREROUTING ${proto}规则 #$rule_num"
                iptables -t nat -D PREROUTING $rule_num
            else
                break
            fi
        done
    done
    
    # 删除POSTROUTING规则
    for proto in tcp udp; do
        while true; do
            rule_num=$(iptables -t nat -L POSTROUTING -n --line-numbers | \
                awk -v rmt="$remote" -v rmt_port="$remoteport" -v p="$proto" \
                '$0 ~ p && $0 ~ rmt && $0 ~ "dpt:" rmt_port {print $1; exit}')
            
            if [ -n "$rule_num" ]; then
                echo "删除POSTROUTING ${proto}规则 #$rule_num"
                iptables -t nat -D POSTROUTING $rule_num
            else
                break
            fi
        done
    done
}
# 检查规则是否已存在
check_rule_exists() {
    local localport=$1
    local remote=$2
    local remoteport=$3
    local allowed_source=$4
    local proto=$5
    
    # 使用iptables的-C选项检查规则是否存在[4](@ref)
    if iptables -t nat -C PREROUTING -s $allowed_source -p $proto --dport $localport -j DNAT --to-destination $remote:$remoteport 2>/dev/null; then
        return 0  # 规则存在
    else
        return 1  # 规则不存在
    fi
}

# 安全添加规则函数
safe_add_rule() {
    local localport=$1
    local remote=$2
    local remoteport=$3
    local allowed_source=$4
    
    for proto in tcp udp; do
        if ! check_rule_exists $localport $remote $remoteport $allowed_source $proto; then
            echo "添加PREROUTING规则: $allowed_source:$localport -> $remote:$remoteport ($proto)"
            iptables -t nat -A PREROUTING -s $allowed_source -p $proto --dport $localport -j DNAT --to-destination $remote:$remoteport
        else
            echo "PREROUTING规则已存在，跳过添加: $allowed_source:$localport -> $remote:$remoteport ($proto)"
        fi
        
        if ! iptables -t nat -C POSTROUTING -p $proto -d $remote --dport $remoteport -j SNAT --to-source $local 2>/dev/null; then
            echo "添加POSTROUTING规则: $remote:$remoteport -> $local ($proto)"
            iptables -t nat -A POSTROUTING -p $proto -d $remote --dport $remoteport -j SNAT --to-source $local
        else
            echo "POSTROUTING规则已存在，跳过添加: $remote:$remoteport -> $local ($proto)"
        fi
    done
}
# 封装的iptables命令，避免重复添加
iptables_no_dup() {
    local cmd="$@"
    local check_cmd=$(echo "$cmd" | sed -e 's/-A/-C/g' -e 's/-I/-C/g')
    
    # 先检查规则是否存在
    if ! eval "iptables $check_cmd" >/dev/null 2>&1; then
        echo "执行: iptables $cmd"
        eval "iptables $cmd"
    else
        echo "规则已存在，跳过: iptables $cmd"
    fi
}
