#!/bin/bash

# 功能：自动检测并安装 iptables（兼容 CentOS/RHEL、Debian/Ubuntu 等主流发行版）
# 作者：根据网络最佳实践编写
# 日期：2025-11-16

# 定义颜色输出函数，方便查看
set_color() {
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
}
set_color

# 打印信息函数
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 1. 检查系统是否已安装 iptables
check_iptables_installed() {
    log_info "检查 iptables 是否已安装..."
    if command -v iptables &> /dev/null; then
        iptables_version=$(iptables --version | head -n1)
        log_success "iptables 已安装: $iptables_version"
        return 0
    else
        log_warn "未在系统 PATH 中找到 iptables 命令。"
        return 1
    fi
}

# 2. 检测 Linux 发行版
detect_linux_distro() {
    log_info "正在检测 Linux 发行版..."
    if [ -f /etc/redhat-release ] || [ -f /etc/centos-release ]; then
        echo "centos"
    elif [ -f /etc/debian_version ] || grep -qi "ubuntu" /etc/os-release; then
        echo "debian"
    else
        log_error "无法识别的 Linux 发行版，或当前发行版不支持自动安装。"
        exit 1
    fi
}

# 3. 根据发行版安装 iptables
install_iptables() {
    local distro=$1
    log_info "开始为 ${distro} 系列系统安装 iptables..."

    case $distro in
        "centos")
            # 对于 CentOS/RHEL 系列，使用 yum 或 dnf[1](@ref)[6](@ref)
            if command -v dnf &> /dev/null; then
                log_info "使用 dnf 包管理器安装 iptables-services..."
                dnf update -y
                dnf install -y iptables-services
            else
                log_info "使用 yum 包管理器安装 iptables..."
                yum update -y
                yum install -y iptables
            fi
            ;;
        "debian")
            # 对于 Debian/Ubuntu 系列，使用 apt[1](@ref)[6](@ref)
            log_info "使用 apt 包管理器安装 iptables 和持久化包..."
            apt update -y
            apt install -y iptables iptables-persistent
            ;;
        *)
            log_error "不支持的发行版: $distro"
            exit 1
            ;;
    esac

    # 再次检查安装是否成功
    if check_iptables_installed; then
        log_success "iptables 安装成功！"
    else
        log_error "iptables 安装可能失败，请检查以上错误信息。"
        exit 1
    fi
}

# 4. 主函数
main() {
    log_info "开始 iptables 安装前检测..."

    if check_iptables_installed; then
        log_success "系统已安装 iptables，无需重复安装。"
        exit 0
    fi

    local distro=$(detect_linux_distro)
    log_info "检测到系统为: $distro"

    install_iptables "$distro"

    log_success "iptables 环境准备完毕！"
    log_warn "注意：新安装的 iptables 默认规则可能是允许所有连接，建议根据安全需求进行配置。"
}

# 执行主函数，并将所有输出（stdout 和 stderr）同时显示在屏幕和记录到文件
main "$@" 2>&1 | tee iptables_install.log
