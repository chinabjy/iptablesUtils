#! /bin/bash
# rm -f iptables4ddns.sh;wget  https://raw.githubusercontent.com/arloor/iptablesUtils/master/iptables4ddns.sh;bash iptables4ddns.sh $localport $remoteport $remotehost [ $remoteIpTempfile——暂存ddns的目标ip,用于定时任务判断时候需要更新iptables转发 ];



localport=$1  #中转端口，自行修改
remoteport=$2  #中转端口，自行修改
remotehost=$3 #中转目标host，自行修改
tempFile=$4
local=$5
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
arr1=(`iptables -L PREROUTING -n -t nat --line-number |grep DNAT|grep "dpt:$localport "|sort -r|awk '{print $1,$3,$9}'|tr " " ":"|tr "\n" " "`)
for cell in ${arr1[@]}  # cell= 1:tcp:to:8.8.8.8:543
do
        arr2=(`echo $cell|tr ":" " "`)  #arr2=(1 tcp to 8.8.8.8 543)
        index=${arr2[0]}
        proto=${arr2[1]}
        targetIP=${arr2[3]}
        targetPort=${arr2[4]}
        echo 清除本机$localport端口到$targetIP:$targetPort的${proto}PREROUTING转发规则$index
        iptables -t nat  -D PREROUTING $index
        echo 清除对应的POSTROUTING规则
        toRmIndexs=(`iptables -L POSTROUTING -n -t nat --line-number|grep $targetIP|grep $targetPort|grep $proto|awk  '{print $1}'|sort -r|tr "\n" " "`)
        for cell1 in ${toRmIndexs[@]} 
        do
            iptables -t nat  -D POSTROUTING $cell1
        done
done


## 建立新的中转规则
iptables -t nat -A PREROUTING -p tcp --dport $localport -j DNAT --to-destination $remote:$remoteport
iptables -t nat -A PREROUTING -p udp --dport $localport -j DNAT --to-destination $remote:$remoteport
iptables -t nat -A POSTROUTING -p tcp -d $remote --dport $remoteport -j SNAT --to-source $local
iptables -t nat -A POSTROUTING -p udp -d $remote --dport $remoteport -j SNAT --to-source $local

