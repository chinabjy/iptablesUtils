#!/bin/bash
# set-ddns-v2.sh - 动态 DDNS iptables 转发管理脚本
# 支持系统: CentOS / Ubuntu / Debian 等

red="\033[31m"
green="\033[32m"
black="\033[0m"

if [ "$EUID" -ne 0 ]; then
    echo -e "${red}请使用 root 用户执行本脚本!!${black}"
    exit 1
fi

# 安装依赖
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

install_package wget bind-utils dnsutils

# 下载 ddns-check-v2.sh
cd /usr/local
rm -f ddns-check-v2.sh
wget -q https://raw.githubusercontent.com/chinabjy/iptablesUtils/master/ddns-check-v2.sh
chmod +x ddns-check-v2.sh

# 启用 rc.local（兼容 CentOS/Ubuntu）
enable_rclocal() {
    if [ ! -f /etc/rc.local ] && [ ! -f /etc/rc.d/rc.local ]; then
        echo "#!/bin/bash" > /etc/rc.local
        chmod +x /etc/rc.local
    fi
    if systemctl list-unit-files | grep -q rc-local.service; then
        systemctl enable rc-local
        systemctl start rc-local
    else
        if [ -f /etc/rc.d/rc.local ]; then
            chmod +x /etc/rc.d/rc.local
        elif [ -f /etc/rc.local ]; then
            chmod +x /etc/rc.local
        fi
    fi
}

enable_rclocal

# 获取本机 IP
local_ip=$(ip -o -4 addr list | grep -Ev '\s(docker|lo)' | awk '{print $4}' | cut -d/ -f1 | grep -Ev '(^127\.|^10\.|^172\.1[6-9]|^172\.2[0-9]|^172\.3[0-1]|^192\.168\.)')
[ -z "$local_ip" ] && local_ip=$(ip -o -4 addr list | grep -Ev '\s(docker|lo)' | awk '{print $4}' | cut -d/ -f1)

# 功能菜单
echo "请选择操作："
echo "1) 新建转发规则"
echo "2) 查看现有转发规则"
echo "3) 删除转发规则"
read -p "输入选项 [1-3]: " choice

case "$choice" in
    1)
        echo "=== 新建转发规则 ==="
        read -p "本地端口号: " localport
        read -p "远程端口号: " remoteport
        read -p "目标 DDNS: " targetDDNS
        read -p "绑定的本地 IP (留空自动获取): " bindip
        [ -z "$bindip" ] && bindip=$local_ip

        # 验证端口
        if ! [[ "$localport" =~ ^[0-9]+$ ]] || ! [[ "$remoteport" =~ ^[0-9]+$ ]]; then
            echo -e "${red}端口必须为数字！${black}"
            exit 1
        fi

        IPrecordfile=${localport}[${targetDDNS}:${remoteport}]

        # 添加开机启动
        if [ -f /etc/rc.d/rc.local ]; then
            RCLOCAL=/etc/rc.d/rc.local
        else
            RCLOCAL=/etc/rc.local
        fi

        echo "rm -f /root/$IPrecordfile" >> $RCLOCAL
        echo "/bin/bash /usr/local/ddns-check-v2.sh $localport $remoteport $targetDDNS $IPrecordfile $bindip &>> /root/iptables${localport}.log" >> $RCLOCAL
        chmod +x $RCLOCAL

        # 添加定时任务
        (crontab -l 2>/dev/null; echo "* * * * * /usr/local/ddns-check-v2.sh $localport $remoteport $targetDDNS $IPrecordfile $bindip &>> /root/iptables${localport}.log") | crontab -

        # 初始执行一次
        bash /usr/local/ddns-check-v2.sh $localport $remoteport $targetDDNS $IPrecordfile $bindip &>> /root/iptables${localport}.log
        echo -e "${green}转发规则已创建，每分钟会自动检查更新！${black}"
        ;;

    2)
        echo "=== 查看现有转发规则 ==="
        echo "PREROUTING (DNAT):"
        iptables -t nat -L PREROUTING -n -v --line-numbers | grep DNAT
        echo "POSTROUTING (SNAT):"
        iptables -t nat -L POSTROUTING -n -v --line-numbers | grep SNAT
        ;;

    3)
        echo "=== 删除转发规则 ==="
        read -p "输入本地端口号: " delport
        read -p "输入目标 DDNS 或 IP (可留空忽略匹配): " delhost

        # 删除 PREROUTING
        while true; do
            if [ -z "$delhost" ]; then
                idx=$(iptables -t nat -L PREROUTING -n --line-number | grep "dpt:$delport" | awk '{print $1}' | tail -n1)
            else
                idx=$(iptables -t nat -L PREROUTING -n --line-number | grep "dpt:$delport" | grep "$delhost" | awk '{print $1}' | tail -n1)
            fi
            [ -z "$idx" ] && break
            echo "删除 PREROUTING 规则 $idx"
            iptables -t nat -D PREROUTING "$idx"
        done

        # 删除 POSTROUTING
        while true; do
            if [ -z "$delhost" ]; then
                idx=$(iptables -t nat -L POSTROUTING -n --line-number | grep "$delport" | awk '{print $1}' | tail -n1)
            else
                idx=$(iptables -t nat -L POSTROUTING -n --line-number | grep "$delhost" | grep "$delport" | awk '{print $1}' | tail -n1)
            fi
            [ -z "$idx" ] && break
            echo "删除 POSTROUTING 规则 $idx"
            iptables -t nat -D POSTROUTING "$idx"
        done
        
        # 删除 /etc/crontab 中对应行
        if [ -f /etc/crontab ]; then
            sed -i "\|/usr/local/ddns-check-v2.sh $delport|d" /etc/crontab
        fi
        
        # 删除 rc.local 中对应行
        if [ -f /etc/rc.d/rc.local ]; then
            sed -i "\|/usr/local/ddns-check-v2.sh $delport|d" /etc/rc.d/rc.local
        elif [ -f /etc/rc.local ]; then
            sed -i "\|/usr/local/ddns-check-v2.sh $delport|d" /etc/rc.local
        fi

        # 删除 crontab 对应任务
        crontab -l | grep -v "$delport" | crontab -
        echo -e "${green}转发规则已删除！${black}"
        ;;

    *)
        echo -e "${red}无效选项！${black}"
        exit 1
        ;;
esac
