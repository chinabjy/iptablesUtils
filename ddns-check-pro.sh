#!/bin/bash

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
    
    log_info "开始删除旧规则: 端口 $localport->$remoteport, 目标 $remote"
    
    # 删除PREROUTING规则
    for proto in tcp udp; do
        local rules=$(iptables -t nat -L PREROUTING --line-numbers -n | awk -v port="$localport" -v src="$allowed_source" -v p="$proto" '$0 ~ p && $0 ~ "dpt:" port " " && $0 ~ src {print $1}' | tac)
        for rule_num in $rules; do
            log_info "删除PREROUTING规则 #$rule_num"
            iptables -t nat -D PREROUTING $rule_num
        done
    done
    
    # 删除POSTROUTING规则
    for proto in tcp udp; do
        local rules=$(iptables -t nat -L POSTROUTING --line-numbers -n | awk -v rmt="$remote" -v rmt_port="$remoteport" -v p="$proto" '$0 ~ p && $0 ~ rmt && $0 ~ "dpt:" rmt_port {print $1}' | tac)
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
# 对于TCP协议，使用multiport模块
# 对于UDP协议，同样使用multiport模块
# 修改后（正确）:
# 对于TCP
iptables_no_dup -t nat -A PREROUTING -s $allowed_source -p tcp -m multiport --dports $localport -j DNAT --to-destination $remote
# 对于UDP
iptables_no_dup -t nat -A PREROUTING -s $allowed_source -p udp -m multiport --dports $localport -j DNAT --to-destination $remote


#iptables_no_dup -t nat -A PREROUTING -s $allowed_source -p tcp --dport $localport -j DNAT --to-destination $remote:$remoteport
#iptables_no_dup -t nat -A PREROUTING -s $allowed_source -p udp --dport $localport -j DNAT --to-destination $remote:$remoteport
iptables_no_dup -t nat -A POSTROUTING -p tcp -d $remote --dport $remoteport -j SNAT --to-source $local
iptables_no_dup -t nat -A POSTROUTING -p udp -d $remote --dport $remoteport -j SNAT --to-source $local

# 验证结果
log_info "验证规则配置..."
iptables -t nat -L PREROUTING -n | grep -E "$localport.*$remote:$remoteport" && \
log_success "PREROUTING规则验证成功" || \
log_error "PREROUTING规则验证失败"

iptables -t nat -L POSTROUTING -n | grep -E "$remote.*$remoteport" && \
log_success "POSTROUTING规则验证成功" || \
log_error "POSTROUTING规则验证失败"

log_success "=== 脚本执行完成 ==="
