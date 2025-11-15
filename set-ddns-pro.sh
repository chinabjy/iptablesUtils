#! /bin/bash

# wget https://raw.githubusercontent.com/arloor/iptablesUtils/master/setCroniptablesDDNS.sh;bash setCroniptablesDDNS.sh

red="\033[31m"
black="\033[0m"

if [ $USER = "root" ];then
	echo "本脚本用途："
    echo "适用于centos7；设置iptables定时任务，以转发流量到ddns的vps上"
    echo
else
    echo   -e "${red}请使用root用户执行本脚本!! ${black}"
    exit 1
fi

cd

echo "正在安装依赖...."
yum install -y wget bind-utils &> /dev/null
cd /usr/local
rm -f /usr/local/ddns-check-pro.sh
wget https://raw.githubusercontent.com/chinabjy/iptablesUtils/master/ddns-check-pro.sh  &> /dev/null
chmod +x /usr/local/ddns-check-pro.sh
echo "Done!"
echo ""

local=$(ip -o -4 addr list | grep -Ev '\s(docker|lo)' | awk '{print $4}' | cut -d/ -f1 | grep -Ev '(^127\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$)|(^10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$)|(^172\.1[6-9]{1}[0-9]{0,1}\.[0-9]{1,3}\.[0-9]{1,3}$)|(^172\.2[0-9]{1}[0-9]{0,1}\.[0-9]{1,3}\.[0-9]{1,3}$)|(^172\.3[0-1]{1}[0-9]{0,1}\.[0-9]{1,3}\.[0-9]{1,3}$)|(^192\.168\.[0-9]{1,3}\.[0-9]{1,3}$)')
if [ "${local}" = "" ]; then
	local=$(ip -o -4 addr list | grep -Ev '\s(docker|lo)' | awk '{print $4}' | cut -d/ -f1 )
fi
echo  local-ip: $local
echo  重新设置iptables转发，支持多端口最大数量15个，连续多端口用冒号连接比如10001:10005,不连续多端口用，连接比如80,443,55

# ... 脚本原有的交互部分 ...
echo -n "本地端口号:" ; read localport
echo -n "远程端口号:" ; read remoteport
echo -n "目标DDNS:" ; read targetDDNS
echo -n "绑定的本地IP地址:" ; read localip
# === 新增：询问允许访问的源IP网段 ===
echo -n "允许访问的源IP网段（例如: 64.32.12.128/28）:" ; read allowed_source


# 判断端口格式
valid=false
# 检查本地端口格式：纯数字 或 N-N 格式
if echo "$localport" | grep -qxE '^[0-9]+(-[0-9]+)?$'; then
    # 检查远程端口格式：纯数字 或 N-N 格式
    if echo "$remoteport" | grep -qxE '^[0-9]+(-[0-9]+)?$'; then
        valid=true
    fi
fi


if [ "$valid" = "" ];then
   echo  -e "${red}本地端口和目标端口请输入数字！！${black}"
   exit 1;
fi

IPrecordfile=${localport}[${targetDDNS}:${remoteport}]
# 开机强制刷新一次
chmod +x /etc/rc.d/rc.local
echo "rm -f /root/$IPrecordfile" >> /etc/rc.d/rc.local
# 替换下面的localport remoteport targetDDNS
echo "/bin/bash /usr/local/ddns-check.sh $localport $remoteport $targetDDNS ${localport}[${targetDDNS}:${remoteport}] $localip $allowed_source &>> /root/iptables${localport}.log" >> /etc/rc.d/rc.local
chmod +x /etc/rc.d/rc.local
# 定时任务，每分钟检查一下
# 修改crontab任务行，添加最后一个参数 $allowed_source
echo "* * * * * root sleep $(( RANDOM % 30 ));  /usr/local/ddns-check-pro.sh $localport $remoteport $targetDDNS ${localport}[${targetDDNS}:${remoteport}] $localip $allowed_source &>> /root/iptables${localport}.log" >> /etc/crontab
#echo "* * * * * root /usr/local/ddns-check-pro.sh $localport $remoteport $targetDDNS $IPrecordfile $localip &>> /root/iptables${localport}.log" >> /etc/crontab
cd
rm -f /root/$IPrecordfile
bash /usr/local/ddns-check.sh $localport $remoteport $targetDDNS $IPrecordfile $localip &>> /root/iptables${localport}.log
echo "done!"
echo "现在每分钟都会检查ddns的ip是否改变，并自动更新"
