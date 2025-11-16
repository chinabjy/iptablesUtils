#!/bin/bash

# 输出日志函数
log_info() {
    echo -e "\e[32m[INFO]\e[0m $1"
}

log_warn() {
    echo -e "\e[33m[WARN]\e[0m $1"
}

log_error() {
    echo -e "\e[31m[ERROR]\e[0m $1"
}

# 检测操作系统类型
OS=$(uname -s)
DISTRO=""
PACKAGE_MANAGER=""

# 获取发行版信息
if [[ -f /etc/os-release ]]; then
    DISTRO=$(grep '^ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"')
elif [[ -f /etc/issue ]]; then
    DISTRO=$(cat /etc/issue | cut -d ' ' -f1)
else
    DISTRO=$(uname -s)
fi

log_info "检测到操作系统: $OS"
log_info "发行版: $DISTRO"

# 确定包管理器
case "$DISTRO" in
    ubuntu|debian)
        PACKAGE_MANAGER="apt"
        ;;
    centos|rhel|fedora)
        PACKAGE_MANAGER="yum"
        ;;
    arch|manjaro)
        PACKAGE_MANAGER="pacman"
        ;;
    suse)
        PACKAGE_MANAGER="zypper"
        ;;
    *)
        log_error "不支持的操作系统: $DISTRO"
        exit 1
        ;;
esac

log_info "使用包管理器: $PACKAGE_MANAGER"

# 安装 iptables
install_iptables() {
    case "$PACKAGE_MANAGER" in
        apt)
            log_info "使用 apt 安装 iptables..."
            sudo apt update && sudo apt install -y iptables iptables-persistent
            ;;
        yum)
            log_info "使用 yum 安装 iptables..."
            sudo yum install -y iptables iptables-services
            ;;
        pacman)
            log_info "使用 pacman 安装 iptables..."
            sudo pacman -Syu --noconfirm iptables
            ;;
        zypper)
            log_info "使用 zypper 安装 iptables..."
            sudo zypper install -y iptables
            ;;
    esac
}

# 禁用 firewalld （如果安装了的话）
disable_firewalld() {
    if command -v firewall-cmd > /dev/null 2>&1; then
        log_info "禁用 firewalld 服务..."
        sudo systemctl stop firewalld
        sudo systemctl disable firewalld
    else
        log_warn "未发现 firewalld 服务，不需要禁用"
    fi
}

# 配置 iptables
configure_iptables() {
    log_info "配置 iptables 规则..."

    # 设置允许所有流量（你可以根据需要修改）
    sudo iptables -P INPUT ACCEPT
    sudo iptables -P FORWARD ACCEPT
    sudo iptables -P OUTPUT ACCEPT

    # 其他 iptables 配置根据需求自定义
    # 例如，允许 ping（ICMP）
    sudo iptables -A INPUT -p icmp --icmp-type 8 -j ACCEPT

    # 保存 iptables 规则（CentOS 7 之后的版本没有 iptables-persistent，可能需要手动保存）
    if command -v service > /dev/null 2>&1; then
        sudo service iptables save
    else
        log_warn "无法自动保存 iptables 规则，请手动保存"
    fi
}

# 检查是否已经安装 iptables
check_iptables_installed() {
    if command -v iptables > /dev/null 2>&1; then
        log_info "iptables 已经安装"
        return 0
    else
        log_warn "iptables 没有安装"
        return 1
    fi
}

# 检查并禁用 firewalld
disable_firewalld

# 安装 iptables
check_iptables_installed || install_iptables

# 配置 iptables
configure_iptables

log_info "iptables 安装并配置完成！"
