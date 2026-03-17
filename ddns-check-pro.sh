#!/bin/bash
# ddns-check-pro.sh - 终极稳定版（不会堆积规则）

########################################
# 随机延迟（避免并发）
########################################
sleep "$(awk 'BEGIN{srand(); printf "%.3f", rand()*3}')"

########################################
# 颜色 & 日志
########################################
RED="\033[31m"
GREEN="\033[32m"
BLUE="\033[34m"
RESET="\033[0m"

log() { echo -e "$(date '+%F %T') - $1"; }
log_success() { log "${GREEN}[SUCCESS]${RESET} $1"; }
log_error()   { log "${RED}[ERROR]${RESET} $1"; }
log_info()    { log "${BLUE}[INFO]${RESET} $1"; }

########################################
# 防重复添加
########################################
iptables_no_dup() {
    local cmd="$@"
    local check_cmd=$(echo "$cmd" | sed 's/-A/-C/')

    if ! eval "iptables $check_cmd" >/dev/null 2>&1; then
        eval "iptables $cmd" && log_success "添加: $cmd" || log_error "失败: $cmd"
    else
        log_info "已存在: $cmd"
    fi
}

########################################
# 🔥 强力清理规则（关键）
# 👉 不看 IP、不看 source，只看端口
########################################
delete_old_rules() {
    local localport=$1
    local remoteport=$2

    log_info "清理所有 $localport / $remoteport 相关规则"

    for proto in tcp udp; do

        # PREROUTING
        iptables -t nat -S PREROUTING | \
        grep " -p $proto " | \
        grep -E "dport(s)?(:| )$localport" | \
        while read r; do
            iptables -t nat $(echo "$r" | sed 's/^-A/-D/')
            log_info "删除 PREROUTING: $r"
        done

        # POSTROUTING
        iptables -t nat -S POSTROUTING | \
        grep " -p $proto " | \
        grep -E "dport(s)?(:| )$remoteport" | \
        while read r; do
            iptables -t nat $(echo "$r" | sed 's/^-A/-D/')
            log_info "删除 POSTROUTING: $r"
        done

    done
}

########################################
# 主逻辑
########################################
localport=$1
remoteport=$2
remotehost=$3
tempFile=${4:-remoteip}
local=$5
allowed_source=$6

if [ -z "$remotehost" ]; then
    log_error "Usage: $0 localport remoteport remotehost [tempFile] [localIP] [allowedSource]"
    exit 1
fi

log_info "参数: localport=$localport remoteport=$remoteport host=$remotehost local=$local source=$allowed_source"

########################################
# 解析域名
########################################
remote=$(getent hosts "$remotehost" | awk '{print $1}' | head -1)

if [ -z "$remote" ]; then
    log_error "域名解析失败: $remotehost"
    exit 1
fi

log_success "解析成功: $remotehost -> $remote"

########################################
# IP变化检测（新增）
########################################
old_ip=""

if [ -f "$tempFile" ]; then
    old_ip=$(cat "$tempFile")
fi

if [ "$remote" = "$old_ip" ]; then
    log_info "IP未变化 ($remote)，跳过"
    exit 0
fi

log_info "IP变化: $old_ip -> $remote"
echo "$remote" > "$tempFile"

########################################
# 🔥 永远先删（核心）
########################################
delete_old_rules "$localport" "$remoteport"

########################################
# 端口处理
########################################
if echo "$localport" | grep -qE '[:,]'; then
    dnat_port="-m multiport --dports $localport"
    snat_port="-m multiport --dports $remoteport"
    dnat_target="$remote"
else
    dnat_port="--dport $localport"
    snat_port="--dport $remoteport"
    dnat_target="$remote:$remoteport"
fi

########################################
# 添加规则
########################################
for src in $allowed_source; do

    # DNAT
    iptables_no_dup -t nat -A PREROUTING -s "$src" -p tcp $dnat_port \
        -j DNAT --to-destination $dnat_target

    iptables_no_dup -t nat -A PREROUTING -s "$src" -p udp $dnat_port \
        -j DNAT --to-destination $dnat_target

    # 🔥 SNAT（必须带 -d）
    iptables_no_dup -t nat -A POSTROUTING -p tcp -d "$remote" $snat_port \
        -j SNAT --to-source "$local"

    iptables_no_dup -t nat -A POSTROUTING -p udp -d "$remote" $snat_port \
        -j SNAT --to-source "$local"
done

########################################
# 验证
########################################
log_info "当前规则检查："

echo "---- PREROUTING ----"
iptables -t nat -L PREROUTING -n | grep "$localport"

echo "---- POSTROUTING ----"
iptables -t nat -L POSTROUTING -n | grep "$remoteport"

log_success "=== 执行完成 ==="
