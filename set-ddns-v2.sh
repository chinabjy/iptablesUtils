#!/bin/bash
# set-ddns-v2.sh
# 自动维护 DDNS iptables 转发规则，支持 CentOS / Ubuntu / Debian
# 功能：
# 1. 新建转发规则
# 2. 查看现有转发规则
# 3. 删除转发规则（按端口号彻底删除，包括 iptables、crontab、rc.local）

red="\033[31m"
green="\033[32m"
black="\033[0m"

if [ "$EUID" -ne 0 ]; then
    echo -e "${red}请使用 root 用户执行本脚本!!${black}"
    exit 1
fi

install_package() {
    if command -v yum >/dev/null 2>&1; then
        yum install -y "$@" &>/dev/null
    elif command -v apt >/dev/null 2>&1; then
        apt update && apt install -y "$@" &>/dev/null
    else
        echo -e "${red}不支持的系统，请手动安装依赖: $*${black}"
        exit 1
    fi
}

echo "正在检测系统并安装依赖..."
install_package wget bind-utils dnsutils cron

# 下载 ddns-check-v2.sh
cd /usr/local
rm -f ddns-check-v2.sh
wget -q https://raw.githubusercontent.com/chinabjy/iptablesUtils/master/ddns-check-v2.sh
chmod +x ddns-check-v2.sh

# 确保 rc.local 可用
if [ -f /etc/rc.d/rc.local ]; then
    RCLOCAL=/etc/rc.d/rc.local
elif [ -f /etc/rc.local ]; then
    RCLOCAL=/etc/rc.local
else
    RCLOCAL=/etc/rc.local
    echo "#!/bin/bash" > $RCLOCAL
    chmod +x $RCLOCAL
fi
chmod +x $RCLOCAL

# 检查 systemd 下 rc-local 服务是否启用
if command -v systemctl >/dev/null 2>&1; then
    if ! systemctl is-enabled rc-local >/dev/null 2>&1; then
        if [ ! -f /etc/systemd/system/rc-local.service ]; then
            cat <<'EOF' > /etc/systemd/system/rc-local.service
[Unit]
Description=/etc/rc.local Compatibility
ConditionPathExists=/etc/rc.local
After=network.target

[Service]
Type=forking
ExecStart=/etc/rc.local start
TimeoutSec=0
StandardOutput=tty
RemainAfterExit=yes
SysVStartPriority=99

[Install]
WantedBy=multi-user.target
EOF
        fi
        chmod +x /etc/rc.local
        systemctl enable rc-local
        systemctl start rc-local
    fi
fi

# 获取本机 IP
local=$(ip -o -4 addr list | grep -Ev '\s(docker|lo)' | awk '{print $4}' | cut -d/ -f1 | grep -Ev '(^127\.|^10\.|^172\.1[6-9]|^172\.2[0-9]|^172\.3[0-1]|^192\.168\.)')
[ -z "$local" ] && local=$(ip -o -4 addr list | grep -Ev '\s(docker|lo)' | awk '{print $4}' | cut -d/ -f1)
echo "本机 IP: $local"

# 主菜单
while true; do
    echo
    echo "请选择操作："
    echo "1. 新建转发规则"
    echo "2. 查看现有转发规则"
    echo "3. 删除转发规则"
    echo "4. 退出"
    read -p "输入选项 [1-4]: " choice

    case $choice in
         1)
            read -p "本地端口号 (支持单端口/范围/逗号分隔，如: 8080,8000:8010,9000): " localport_input
            read -p "远程端口号 (格式需与本地端口对应): " remoteport_input
            read -p "目标 DDNS: " targetDDNS
            read -p "绑定的本地IP地址: " localip

            # 如果没有输入本地 IP，则使用自动获取的 IP 地址
            if [ -z "$localip" ]; then
                localip=$local
            fi

            # 验证端口格式（支持数字、逗号分隔和范围，范围使用冒号）
            if ! echo "$localport_input" | grep -Eq '^[0-9]+([,:][0-9]+)*$' || ! echo "$remoteport_input" | grep -Eq '^[0-9]+([,:][0-9]+)*$'; then
                echo -e "${red}端口格式错误！支持单端口、范围(如8000:8010)或逗号分隔列表${black}"
                continue
            fi


            # 创建记录字符串，直接使用输入的端口格式
            IPrecordfile="${localport_input}[${targetDDNS}:${remoteport_input}]"

            # 写入 rc.local 启动命令（避免重复）
            grep -F "/usr/local/ddns-check-v2.sh $localport_input $remoteport_input $targetDDNS" $RCLOCAL >/dev/null 2>&1 || \
                echo "/bin/bash /usr/local/ddns-check-v2.sh $localport_input $remoteport_input $targetDDNS $IPrecordfile $localip &>> /root/iptables_${localport_input}.log" >> $RCLOCAL

            # 添加 crontab 任务到系统级 crontab（避免重复）
            cronjob="* * * * * root /usr/local/ddns-check-v2.sh $localport_input $remoteport_input $targetDDNS $IPrecordfile $localip &>> /root/iptables_${localport_input}.log"
            if ! grep -F "$cronjob" /etc/crontab >/dev/null 2>&1; then
                echo "$cronjob" >> /etc/crontab
                echo -e "${green}成功将定时任务添加到 /etc/crontab。${black}"
            else
                echo -e "${green}定时任务已存在，无需重复添加。${black}"
            fi


            # 强制添加规则，绕过 IP 检查
            bash /usr/local/ddns-check-v2.sh $localport_input $remoteport_input $targetDDNS $IPrecordfile $localip force_add

            echo -e "${green}多端口转发规则已创建，每分钟会自动检查 DDNS 并更新 iptables${black}"
            ;;


        2)
            echo "PREROUTING 转发规则:"
            iptables -t nat -L PREROUTING -n --line-number | grep DNAT || echo "无"
            echo "POSTROUTING 转发规则:"
            iptables -t nat -L POSTROUTING -n --line-number | grep SNAT || echo "无"
            echo "crontab 定时任务:"
            cat /etc/crontab | grep ddns-check-v2.sh || echo "无"
            echo "rc.local 任务:"
            grep ddns-check-v2.sh $RCLOCAL || echo "无"
            ;;

        3)
            read -p "请输入需要删除的本地端口号 (支持单端口/多端口): " delport_input
            if ! echo "$delport_input" | grep -Eq '^[0-9]+([,-][0-9]+)*$'; then
                echo -e "${red}端口格式错误！支持单端口、范围(如8000-8010)或逗号分隔列表${black}"
                continue
            fi

            # 检查端口类型：单端口还是多端口
            if echo "$delport_input" | grep -qE '[,-]'; then
                port_type="multiport"
            else
                port_type="single"
            fi

            echo "检测到端口类型: $port_type"

            # 删除 PREROUTING 规则（根据端口类型采用不同策略）
            if [ "$port_type" = "multiport" ]; then
                # 多端口：使用 multiport 匹配删除
                indices=($(iptables -t nat -L PREROUTING -n --line-number | grep "multiport dports $delport_input" | awk '{print $1}' | sort -r))
                for i in "${indices[@]}"; do
                    echo "删除 PREROUTING 多端口规则 $i (端口: $delport_input)"
                    iptables -t nat -D PREROUTING "$i"
                done
            else
                # 单端口：使用传统方式删除
                indices=($(iptables -t nat -L PREROUTING -n --line-number | grep "dpt:$delport_input" | awk '{print $1}' | sort -r))
                for i in "${indices[@]}"; do
                    echo "删除 PREROUTING 规则 $i (端口: $delport_input)"
                    iptables -t nat -D PREROUTING "$i"
                done
            fi

            # 删除 POSTROUTING 规则（同样根据端口类型处理）
            if [ "$port_type" = "multiport" ]; then
                # 多端口：使用 multiport 匹配删除[1](@ref)[5](@ref)
                indices=($(iptables -t nat -L POSTROUTING -n --line-number | grep "multiport dports $delport_input" | awk '{print $1}' | sort -r))
                for i in "${indices[@]}"; do
                    echo "删除 POSTROUTING 多端口规则 $i (端口: $delport_input)"
                    iptables -t nat -D POSTROUTING "$i"
                done
            else
                # 单端口：使用传统方式删除
                indices=($(iptables -t nat -L POSTROUTING -n --line-number | grep "dpt:$delport_input" | awk '{print $1}' | sort -r))
                for i in "${indices[@]}"; do
                    echo "删除 POSTROUTING 规则 $i (端口: $delport_input)"
                    iptables -t nat -D POSTROUTING "$i"
                done
            fi

            # 删除 /etc/crontab 中匹配的任务
            sed -i "/$delport_input/d" /etc/crontab
            
            # 删除 rc.local 中匹配的任务
            sed -i "\|$delport_input|d" $RCLOCAL
            
            echo -e "${green}端口 $delport_input 的转发规则已删除（iptables、crontab、rc.local）${black}"
            ;;


        4)
            exit 0
            ;;

        *)
            echo -e "${red}无效选项${black}"
            ;;
    esac
done
