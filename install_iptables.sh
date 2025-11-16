#!/bin/bash

# 功能：自动检测并安装 iptables（兼容 CentOS/RHEL/Rocky Linux/AlmaLinux、Debian/Ubuntu 等主流发行版）
# 版本：2.0
# 更新说明：增强系统兼容性、错误处理和安装后服务管理

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
    
    # 多种方式检查 iptables 是否存在[3](@ref)[6](@ref)
    if command -v iptables &> /dev/null || iptables -V &> /dev/null; then
        iptables_version=$(iptables --version 2>/dev/null | head -n1)
        log_success "iptables 已安装: ${iptables_version:-'版本信息不可用'}"
        return 0
    else
        log_warn "未在系统 PATH 中找到 iptables 命令。"
        return 1
    fi
}

# 2. 增强版 Linux 发行版检测[3](@ref)[5](@ref)[6](@ref)
detect_linux_distro() {
    log_info "正在检测 Linux 发行版..."
    
    local distro="unknown"
    
    # 检查 /etc/os-release 文件 (最标准的方法)
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        case ${ID} in
            centos|rhel|fedora|rocky|almalinux) distro="centos" ;;
            debian|ubuntu|kali) distro="debian" ;;
            *) distro="unknown" ;;
        esac
    fi
    
    # 如果通过 os-release 无法识别，尝试传统方法
    if [ "$distro" = "unknown" ]; then
        if [ -f /etc/redhat-release ] || [ -f /etc/centos-release ] || [ -f /etc/rocky-release ]; then
            distro="centos"
        elif [ -f /etc/debian_version ] || grep -qi "debian" /etc/issue 2>/dev/null || grep -qi "ubuntu" /etc/issue 2>/dev/null; then
            distro="debian"
        elif grep -qi "centos" /etc/issue 2>/dev/null || grep -qi "red hat" /etc/issue 2>/dev/null; then
            distro="centos"
        fi
    fi
    
    if [ "$distro" = "unknown" ]; then
        log_error "无法自动识别 Linux 发行版。"
        log_info "请手动安装 iptables:"
        log_info "  - Debian/Ubuntu: apt install iptables"
        log_info "  - CentOS/RHEL: yum install iptables-services 或 dnf install iptables"
        exit 1
    fi
    
    echo "$distro"
}

# 3. 处理 CentOS/RHEL 系统中的 firewalld[8](@ref)
handle_firewalld_centos() {
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        log_warn "检测到 firewalld 正在运行，iptables 可能与它冲突。"
        read -p "是否停止并禁用 firewalld？(y/N): " choice
        case "$choice" in
            y|Y)
                log_info "停止 firewalld..."
                systemctl stop firewalld
                systemctl disable firewalld
                log_success "firewalld 已停止并禁用"
                ;;
            *)
                log_info "保留 firewalld 运行，请注意可能的冲突。"
                ;;
        esac
    fi
}

# 4. 根据发行版安装 iptables[1](@ref)[4](@ref)[8](@ref)
install_iptables() {
    local distro=$1
    log_info "开始为 ${distro} 系列系统安装 iptables..."

    case $distro in
        "centos")
            # 处理 firewalld
            handle_firewalld_centos
            
            # 安装 iptables[1](@ref)[8](@ref)
            if command -v dnf &> /dev/null; then
                log_info "使用 dnf 包管理器安装 iptables-services..."
                dnf update -y && dnf install -y iptables-services
            else
                log_info "使用 yum 包管理器安装 iptables-services..."
                yum update -y && yum install -y iptables-services
            fi
            
            # 启动并启用 iptables 服务[1](@ref)
            log_info "启动 iptables 服务..."
            systemctl start iptables
            systemctl enable iptables
            ;;
            
        "debian")
            # 对于 Debian/Ubuntu 系列[1](@ref)[4](@ref)
            log_info "使用 apt 包管理器安装 iptables..."
            apt update -y && apt install -y iptables
            
            # 尝试安装持久化包（可选）
            if apt-cache show iptables-persistent > /dev/null 2>&1; then
                log_info "安装 iptables-persistent 包用于规则持久化..."
                apt install -y iptables-persistent
            else
                log_info "iptables-persistent 包不可用，规则持久化需要手动处理。"
            fi
            ;;
    esac

    # 检查安装是否成功
    if check_iptables_installed; then
        log_success "iptables 安装成功！"
    else
        log_error "iptables 安装失败！"
        exit 1
    fi
}

# 5. 安装后配置建议
post_install_config() {
    log_info "=== iptables 安装后配置建议 ==="
    
    case $(detect_linux_distro) in
        "centos")
            log_info "1. 保存当前规则: iptables-save > /etc/sysconfig/iptables"
            log_info "2. 查看规则: iptables -L -n -v"
            log_info "3. 服务管理: systemctl status iptables"
            ;;
        "debian")
            log_info "1. 保存规则: netfilter-persistent save 或 iptables-save > /etc/iptables/rules.v4"
            log_info "2. 查看规则: iptables -L -n -v"
            log_info "3. 确保重启后规则持久化"
            ;;
    esac
    
    log_warn "注意：新安装的 iptables 默认规则可能是允许所有连接。"
    log_warn "建议根据安全需求配置适当的防火墙规则。"
}

# 6. 主函数
main() {
    log_info "开始 iptables 自动安装流程..."
    log_info "当前时间: $(date)"
    log_info "系统信息: $(uname -a)"
    
    # 检查权限
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用 root 权限运行此脚本 (sudo $0)"
        exit 1
    fi

    if check_iptables_installed; then
        log_success "系统已安装 iptables，无需重复安装。"
        iptables -V
        exit 0
    fi

    local distro=$(detect_linux_distro)
    log_success "检测到系统为: $distro"

    # 确认安装
    read -p "是否继续安装 iptables？(Y/n): " choice
    case "$choice" in
        n|N) 
            log_info "用户取消安装。"
            exit 0
            ;;
        *) 
            install_iptables "$distro"
            post_install_config
            ;;
    esac

    log_success "iptables 环境准备完毕！"
}

# 脚本执行入口
if [ "${1}" = "--test" ]; then
    echo "测试模式："
    echo "发行版检测: $(detect_linux_distro)"
    check_iptables_installed
else
    # 执行主函数并记录日志
    log_file="iptables_install_$(date +%Y%m%d_%H%M%S).log"
    log_info "详细日志将保存到: $log_file"
    main "$@" 2>&1 | tee "$log_file"
fi
