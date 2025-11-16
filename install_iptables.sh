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

# 启用并启动 iptables 服务
enable_iptables() {
    case "$PACKAGE_MANAGER" in
        apt|yum)
            log_info "启用并启动 iptables 服务..."
            sudo systemctl enable iptables
            sudo systemctl start iptables
            ;;
        *)
            log_warn "不需要启用 iptables 服务"
            ;;
    esac
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

# 安装 iptables
check_iptables_installed || install_iptables

# 启用 iptables 服务
enable_iptables

log_info "iptables 安装并配置完成！"
