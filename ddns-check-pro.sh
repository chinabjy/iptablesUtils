#!/bin/bash
# ddns-check-pro.sh - 修复版（绝不堆积规则）

sleep "$(awk 'BEGIN{srand(); printf "%.3f", rand()*5}')"

RED="\033[31m"
GREEN="\033[32m"
BLUE="\033[34m"
RESET="\033[0m"

log() { echo -e "$(date '+%F %T') - $1"; }
log_success() { log "${GREEN}[SUCCESS]${RESET} $1"; }
log_error()   { log "${RED}[ERROR]${RESET} $1"; }
log_info()    { log "${BLUE}[INFO]${RESET} $1"; }

########################################
# 强力删除规则（关键修复）
########################################
delete_old_rules() {
    local localport=$1
    local remoteport=$2
    local allowed_source=$3

    log_info "清理旧规则 (不依赖IP)"

    for proto in tcp udp; do
        for src in $allowed_source; do

            # PREROUTING（只按端口删）
            iptables -t nat -S PREROUTING | \
            grep " -p $proto " | \
            grep -E "dport(s)?(:| )$localport" | \
            grep " -s $src " | \
            while read r; do
                iptables -t nat $(echo "$r" | sed 's/^-A/-D/')
                log_info "删除PREROUTING: $r"
            done

            # POSTROUTING（不再匹配 -d IP）
            iptables -t nat -S POSTROUTING | \
            grep " -p $proto " | \
            grep -E "dport(s)?(:| )$remoteport" | \
            grep " -s $src " | \
            while read r; do
                iptables -t nat $(echo "$r" | sed 's/^-A/-D/')
                log_info "删除POSTROUTING: $r"
            done

        done
    done
}

########################################
# 防重复添加
########################################
iptables_no_dup() {
    local cmd="$@"
    local check_cmd=$(echo "$cmd" | sed -e 's/-A/-C/g')

    if ! eval "iptables $check_cmd" >/dev/null 2>&1; then
        eval "iptables $cmd" && log_success "添加: $cmd" || log_error "失败: $cmd"
    else
        log_info "已存在: $cmd"
    fi
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
    log_error "Usage: $0 localport remoteport remotehost [file] [localIP] [source]"
    exit 1
fi

log_info "参数: $*"

remote=$(getent hosts "$remotehost" | awk '{print $1}' | head -1)
[ -z "$remote" ] && log_error "解析失败" && exit 1

log_success "解析: $remotehost -> $remote"

########################################
# ⭐ 不再依赖IP变化（关键改动）
########################################

# 永远先删
delete_old_rules "$localport" "$remoteport" "$allowed_source"

# 端口处理
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

    iptables_no_dup -t nat -A PREROUTING -s "$src" -p tcp $dnat_port -j DNAT --to-destination $dnat_target
    iptables_no_dup -t nat -A PREROUTING -s "$src" -p udp $dnat_port -j DNAT --to-destination $dnat_target

    iptables_no_dup -t nat -A POSTROUTING -s "$src" -p tcp $snat_port -j SNAT --to-source "$local"
    iptables_no_dup -t nat -A POSTROUTING -s "$src" -p udp $snat_port -j SNAT --to-source "$local"

done

########################################
# 验证
########################################
log_info "当前规则："
iptables -t nat -L PREROUTING -n | grep "$localport"
iptables -t nat -L POSTROUTING -n | grep "$remoteport"

log_success "完成"
