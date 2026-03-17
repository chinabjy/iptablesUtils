#!/bin/bash
# ddns-check.sh - DDNS自动更新iptables端口转发，支持多端口、多源IP
# 优化删除旧规则逻辑，支持IP网段变化，不依赖行号

# 暂停 0~10 秒，避免多脚本同时运行冲突
sleep "$(awk 'BEGIN{srand(); printf "%.3f", rand()*10}')"

# 颜色定义
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
RESET="\033[0m"

# 日志函数
log() { echo -e "$(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_success() { log "${GREEN}[SUCCESS]${RESET} $1"; }
log_error()   { log "${RED}[ERROR]${RESET} $1"; }
log_info()    { log "${BLUE}[INFO]${RESET} $1"; }

# 防止重复添加规则
iptables_no_dup() {
    local cmd="$@"
    local check_cmd=$(echo "$cmd" | sed -e 's/-A/-C/g' -e 's/-I/-C/g')
    if ! eval "iptables $check_cmd" >/dev/null 2>&1; then
        log_info "执行: iptables $cmd"
        eval "iptables $cmd" && log_success "规则添加成功" || log_error "规则添加失败: iptables $cmd"
    else
        log_info "规则已存在，跳过: iptables $cmd"
    fi
}

# 删除旧规则
delete_old_rules() {
    local localport=$1
    local remote=$2
    local remoteport=$3
    local allowed_source=$4

    log_info "删除旧规则: $localport->$remoteport, 目标IP: $remote, 源: $allowed_source"

    for proto in tcp udp; do
        for src in $allowed_source; do
            # PREROUTING 删除旧规则
            iptables -t nat -S PREROUTING | grep " -s $src " | grep " -p $proto " | grep "dpt:$localport" | while read r; do
                iptables -t nat $(echo "$r" | sed 's/^-A/-D/') && log_info "删除PREROUTING规则: $r"
            done

            # POSTROUTING 删除旧规则
            iptables -t nat -S POSTROUTING | grep " -s $src " | grep " -p $proto " | grep "dpt:$remoteport" | grep " -d $remote " | while read r; do
                iptables -t nat $(echo "$r" | sed 's/^-A/-D/') && log_info "删除POSTROUTING规则: $r"
            done
        done
    done
}

# ================== 主逻辑 ==================
localport=$1
remoteport=$2
remotehost=$3
tempFile=$4
local=$5
allowed_source=$6

# 默认文件名
if [ -z "$tempFile" ]; then
    tempFile="remoteip"
fi

if [ -z "$remotehost" ]; then
    log_error "Usage: bash $0 localport remoteport remotehost [tempFile] [localIP] [allowedSource]"
    exit 1
fi

log_info "参数: localport=$localport, remoteport=$remoteport, remotehost=$remotehost, local=$local, allowed_source=$allowed_source"

# 解析域名
remote=$(host -t a "$remotehost" 2>/dev/null | grep -Eo "([0-9]{1,3}\.){3}[0-9]{1,3}" | head -1)
if [ -z "$remote" ]; then
    log_error "无法解析域名: $remotehost"
    exit 1
fi
log_success "域名解析成功: $remotehost -> $remote"

# 检查IP变化
lastremote=$(cat "/root/$tempFile" 2>/dev/null)
if [ "$lastremote" = "$remote" ]; then
    log_info "IP未变化 ($remote)，退出"
    exit 0
fi

log_info "IP变化: $lastremote -> $remote"
echo "$remote" > "/root/$tempFile"

# 删除旧规则
delete_old_rules "$localport" "$remote" "$remoteport" "$allowed_source"

# 构建端口匹配
if echo "$localport" | grep -qE '[:,]'; then
    dnat_port_tcp="-m multiport --dports $localport"
    dnat_port_udp="-m multiport --dports $localport"
    snat_port_tcp="-m multiport --dports $remoteport"
    snat_port_udp="-m multiport --dports $remoteport"
    dnat_target="$remote"        # 多端口DNAT只能指定IP
else
    dnat_port_tcp="--dport $localport"
    dnat_port_udp="--dport $localport"
    snat_port_tcp="--dport $remoteport"
    snat_port_udp="--dport $remoteport"
    dnat_target="$remote:$remoteport"
fi

# 添加新规则
for src in $allowed_source; do
    iptables_no_dup -t nat -A PREROUTING -s "$src" -p tcp $dnat_port_tcp -j DNAT --to-destination $dnat_target
    iptables_no_dup -t nat -A PREROUTING -s "$src" -p udp $dnat_port_udp -j DNAT --to-destination $dnat_target

    iptables_no_dup -t nat -A POSTROUTING -s "$src" -p tcp -d "$remote" $snat_port_tcp -j SNAT --to-source "$local"
    iptables_no_dup -t nat -A POSTROUTING -s "$src" -p udp -d "$remote" $snat_port_udp -j SNAT --to-source "$local"
done

# 验证
log_info "验证规则配置..."
iptables -t nat -L PREROUTING -n | grep -E "$localport.*$remote" && log_success "PREROUTING规则验证成功" || log_error "PREROUTING规则验证失败"
iptables -t nat -L POSTROUTING -n | grep -E "$remote.*$remoteport" && log_success "POSTROUTING规则验证成功" || log_error "POSTROUTING规则验证失败"

log_success "=== 脚本执行完成 ==="
