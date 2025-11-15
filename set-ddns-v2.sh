#!/bin/bash

red="\033[31m"
black="\033[0m"

if [ "$EUID" -ne 0 ]; then
    echo -e "${red}请使用root用户执行本脚本!!${black}"
    exit 1
fi

echo "正在检测系统并安装依赖..."
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

# 下载 ddns-check.sh
cd /usr/local
rm -f ddns-check.sh
wget -q https://raw.githubusercontent.com/chinabjy/iptablesUtils/master/ddns-check-v2.sh
chmod +x ddns-check.sh

# 获取本机 IP
local=$(ip -o -4 addr list | grep -Ev '\s(docker|lo)' | awk '{print $4}' | cut -d/ -f1 | grep -Ev '(^127\.|^10\.|^172\.1[6-9]|^172\.2[0-9]|^172\.3[0-1]|^192\.168\.)')
[ -z "$local" ] && local=$(ip -o -4 addr list | grep -Ev '\s(docker|lo)' | awk '{print $4}' | cut -d/ -f1)
echo "本机 IP: $local"

# 用户输入
read -p "本地端口号: " localport
read -p "远程端口号: " remoteport
read -p "目标 DDNS: " targetDDNS
read -p "绑定的本地IP地址: " localip

# 验证端口
if ! [[ "$localport" =~ ^[0-9]+$ ]] || ! [[ "$remoteport" =~ ^[0-9]+$ ]]; then
    echo -e "${red}本地端口和目标端口请输入数字！！${black}"
    exit 1
fi

IPrecordfile=${localport}[${targetDDNS}:${remoteport}]

# 添加开机启动
if [ -f /etc/rc.d/rc.local ]; then
    RCLOCAL=/etc/rc.d/rc.local
elif [ -f /etc/rc.local ]; then
    RCLOCAL=/etc/rc.local
else
    RCLOCAL=/etc/rc.local
    echo "#!/bin/bash" > $RCLOCAL
    chmod +x $RCLOCAL
fi

echo "rm -f /root/$IPrecordfile" >> $RCLOCAL
echo "/bin/bash /usr/local/ddns-check-v2.sh $localport $remoteport $targetDDNS $IPrecordfile $localip &>> /root/iptables${localport}.log" >> $RCLOCAL
chmod +x $RCLOCAL

# 添加定时任务
(crontab -l 2>/dev/null; echo "* * * * * /usr/local/ddns-check-v2.sh $localport $remoteport $targetDDNS $IPrecordfile $localip &>> /root/iptables${localport}.log") | crontab -

# 初始执行一次
bash /usr/local/ddns-check.sh $localport $remoteport $targetDDNS $IPrecordfile $localip &>> /root/iptables${localport}.log

echo "done! 每分钟都会检查 DDNS 的 IP 并自动更新 iptables。"
