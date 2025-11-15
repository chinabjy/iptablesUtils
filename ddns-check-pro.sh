#!/bin/bash
# 暂停范围：0.000–10.000 秒
sleep "$(awk 'BEGIN{srand(); printf "%.3f", rand()*10}')"


# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"

# 日志函数
log() {
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

log_success() {
    log "${GREEN}[SUCCESS]${RESET} $1"
}

log_error() {
    log "${RED}[ERROR]${RESET} $1"
}

log_info() {
    log "${BLUE}[INFO]${RESET} $1"
}


# 首先定义所有函数
iptables_no_dup() {
    local cmd="$@"
    local check_cmd=$(echo "$cmd" | sed -e 's/-A/-C/g' -e 's/-I/-C/g')
    
    if ! eval "iptables $check_cmd" >/dev/null 2>&1; then
        log_info "执行: iptables $cmd"
        if eval "iptables $cmd"; then
            log_success "规则添加成功"
            return 0
        else
            log_error "规则添加失败: iptables $cmd"
            return 1
        fi
    else
        log_info "规则已存在，跳过: iptables $cmd"
        return 0
    fi
}

delete_old_rules() {
    local localport=$1
    local remote=$2
    local remoteport=$3
    local allowed_source=$4
    
    log_info "开始删除旧规则: 端口 $localport->$remoteport, 目标 $remote, 源 $allowed_source"
    
    # 删除PREROUTING规则 (保持不变，你的逻辑已经很精确)
    for proto in tcp udp; do
        local rules=$(iptables -t nat -L PREROUTING --line-numbers -n | awk -v port="$localport" -v src="$allowed_source" -v p="$proto" '$0 ~ p && $0 ~ "dpt:" port " " && $0 ~ src {print $1}' | tac)
        for rule_num in $rules; do
            log_info "删除PREROUTING规则 #$rule_num"
            iptables -t nat -D PREROUTING $rule_num
        done
    done
    
    # 删除POSTROUTING规则 (增强匹配精确度)
    for proto in tcp udp; do
        # 关键修改：在匹配条件中加入源IP ($local) 和更精确的端口匹配
        local rules=$(iptables -t nat -L POSTROUTING --line-numbers -n | awk -v rmt="$remote" -v rmt_port="$remoteport" -v src_ip="$local" -v p="$proto" '$0 ~ p && $0 ~ rmt && $0 ~ "dpt:" rmt_port " " && $0 ~ src_ip {print $1}' | tac)
        for rule_num in $rules; do
            log_info "删除POSTROUTING规则 #$rule_num"
            iptables -t nat -D POSTROUTING $rule_num
        done
    done
}

# 主脚本逻辑开始
log_info "=== DDNS iptables转发脚本开始执行 ==="

localport=$1
remoteport=$2
remotehost=$3
tempFile=$4
local=$5
allowed_source=$6

if [ "$4" = "" ]; then
    tempFile="remoteip"
fi

# 参数验证
if [ "$remotehost" = "" ]; then
    log_error "缺少参数: Usage: bash script.sh localport remoteport remotehost [tempFile] [localIP] [allowedSource]"
    exit 1
fi

log_info "参数: localport=$localport, remoteport=$remoteport, remotehost=$remotehost, local=$local, allowed_source=$allowed_source"

# 域名解析
log_info "解析域名: $remotehost"
remote=$(host -t a $remotehost 2>/dev/null | grep -E -o "([0-9]{1,3}[\.]){3}[0-9]{1,3}" | head -1)

if [ -z "$remote" ]; then
    log_error "无法解析域名: $remotehost"
    exit 1
fi

log_success "域名解析成功: $remotehost -> $remote"

# 检查IP变化
lastremote=$(cat "/root/$tempFile" 2>/dev/null)
if [ "$lastremote" = "$remote" ]; then
    log_info "IP地址未变化 ($remote)，退出脚本"
    exit 0
fi

log_info "检测到IP变化: 旧IP: $lastremote → 新IP: $remote"
echo "$remote" > "/root/$tempFile"

# 执行规则更新
log_info "开始更新iptables规则..."
delete_old_rules $localport $remote $remoteport $allowed_source

log_info "添加新规则..."


# 智能判断端口类型并构建相应的匹配条件
# 判断是否为多端口（包含冒号:或逗号,）
if echo "$localport" | grep -qE '[:,]'; then
    dnat_port_match_tcp="-m multiport --dports $localport"
    dnat_port_match_udp="-m multiport --dports $localport"
    snat_port_match_tcp="-m multiport --dports $remoteport"
    snat_port_match_udp="-m multiport --dports $remoteport"
    # 对于多端口的一对一映射，DNAT 目标只写IP
    dnat_target="$remote"
else
    # 单端口，不使用 multiport 模块
    dnat_port_match_tcp="--dport $localport"
    dnat_port_match_udp="--dport $localport"
    snat_port_match_tcp="--dport $remoteport"
    snat_port_match_udp="--dport $remoteport"
    # 对于单端口，DNAT 目标需要明确指定端口
    dnat_target="$remote:$remoteport"
fi

# 使用变量动态构建 PREROUTING (DNAT) 规则
iptables_no_dup -t nat -A PREROUTING -s $allowed_source -p tcp $dnat_port_match_tcp -j DNAT --to-destination $dnat_target
iptables_no_dup -t nat -A PREROUTING -s $allowed_source -p udp $dnat_port_match_udp -j DNAT --to-destination $dnat_target

# 使用变量动态构建 POSTROUTING (SNAT) 规则
iptables_no_dup -t nat -A POSTROUTING -p tcp -d $remote $snat_port_match_tcp -j SNAT --to-source $local
iptables_no_dup -t nat -A POSTROUTING -p udp -d $remote $snat_port_match_udp -j SNAT --to-source $local



# 验证结果
log_info "验证规则配置..."
iptables -t nat -L PREROUTING -n | grep -E "$localport.*$remote:$remoteport" && \
log_success "PREROUTING规则验证成功" || \
log_error "PREROUTING规则验证失败"

iptables -t nat -L POSTROUTING -n | grep -E "$remote.*$remoteport" && \
log_success "POSTROUTING规则验证成功" || \
log_error "POSTROUTING规则验证失败"

log_success "=== 脚本执行完成 ==="
