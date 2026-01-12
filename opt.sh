#!/bin/bash

# ====================================================
# 系统初始化与优化脚本 (Debian/Ubuntu/CentOS/Alma)
# ====================================================

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

# 1. 环境检查
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 必须以 root 权限运行此脚本。${NC}"
        exit 1
    fi
}

check_package_manager() {
    if command -v apt &> /dev/null; then
        PACKAGE_MANAGER="apt"
    elif command -v dnf &> /dev/null; then
        PACKAGE_MANAGER="dnf"
    elif command -v yum &> /dev/null; then
        PACKAGE_MANAGER="yum"
    else
        echo -e "${RED}错误: 未检测到支持的包管理器 (apt, dnf, yum)${NC}"
        exit 1
    fi
}

# 统一安装函数
pkg_install() {
    case "$PACKAGE_MANAGER" in
        apt) apt install -y "$@" ;;
        dnf|yum) "$PACKAGE_MANAGER" install -y "$@" ;;
    esac
}

# 2. 系统更新
update_system() {
    echo -e "${YELLOW}---> 是否要更新系统软件包？(y/n)${NC}"
    read -r update_choice
    if [[ "$update_choice" =~ ^[Yy]$ ]]; then
        case "$PACKAGE_MANAGER" in
            apt)
                apt update && apt dist-upgrade -y && apt autoremove --purge -y
                ;;
            dnf|yum)
                "$PACKAGE_MANAGER" makecache && "$PACKAGE_MANAGER" update -y
                ;;
        esac
    else
        echo -e "${GREEN}跳过系统更新。${NC}"
    fi
}

# 3. 基础依赖安装
install_base_tools() {
    echo -e "${GREEN}正在安装基础依赖工具...${NC}"
    local packages="curl vnstat sudo vim nload lsof dnsutils btop jq virt-what haveged"
    
    if [[ "$PACKAGE_MANAGER" != "apt" ]]; then
        pkg_install epel-release
    fi
    
    pkg_install $packages
    systemctl enable --now haveged
}

# 4. Swap 自动配置
configure_swap() {
    local virtualization_type=$(virt-what 2>/dev/null)
    if [[ "$virtualization_type" == *"lxc"* || "$virtualization_type" == *"openvz"* ]]; then
        echo -e "${YELLOW}检测到容器虚拟化 ($virtualization_type)，跳过 Swap 配置。${NC}"
        return
    fi

    local swap=$(free -m | awk '/^Swap:/{print $2}')
    if [ "$swap" -eq 0 ]; then
        echo -e "${GREEN}检测到未配置 Swap，正在创建 1GB 虚拟内存...${NC}"
        fallocate -l 1G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=1024
        chmod 600 /swapfile
        mkswap /swapfile && swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    else
        echo -e "${GREEN}系统已存在 Swap ($swap MB)，跳过。${NC}"
    fi
}

# 5. 内核参数深度优化 (按要求覆盖 /etc/sysctl.conf)
optimize_kernel() {
    echo -e "${GREEN}正在配置内核参数 (/etc/sysctl.conf)...${NC}"
    
    # 备份原配置
    [ -f /etc/sysctl.conf ] && cp /etc/sysctl.conf /etc/sysctl.conf.bak

    cat > /etc/sysctl.conf << 'EOF'
# 文件句柄限制
fs.file-max                     = 6815744

# 网络队列与连接优化
net.ipv4.tcp_max_syn_backlog    = 8192
net.core.somaxconn              = 8192
net.ipv4.tcp_tw_reuse            = 1
net.ipv4.tcp_abort_on_overflow  = 1

# BBR 拥塞控制与队列算法
net.core.default_qdisc          = fq
net.ipv4.tcp_congestion_control = bbr

# TCP 特性优化
net.ipv4.tcp_no_metrics_save    = 1
net.ipv4.tcp_ecn                = 0
net.ipv4.tcp_frto               = 0
net.ipv4.tcp_mtu_probing         = 0
net.ipv4.tcp_rfc1337            = 1
net.ipv4.tcp_sack               = 1
net.ipv4.tcp_fack               = 1
net.ipv4.tcp_window_scaling     = 1
net.ipv4.tcp_adv_win_scale      = 2
net.ipv4.tcp_moderate_rcvbuf    = 1
net.ipv4.tcp_fin_timeout        = 30

# 缓冲区调整 (适合高速大带宽)
net.ipv4.tcp_rmem               = 4096 87380 67108864
net.ipv4.tcp_wmem               = 4096 65536 67108864
net.core.rmem_max               = 67108864
net.core.wmem_max               = 67108864
net.ipv4.udp_rmem_min           = 8192
net.ipv4.udp_wmem_min           = 8192

# 端口范围与时间戳
net.ipv4.ip_local_port_range    = 1024 65535
net.ipv4.tcp_timestamps         = 1

# 路由与转发
net.ipv4.conf.all.rp_filter     = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.ip_forward             = 1
net.ipv6.conf.all.forwarding    = 1
net.ipv6.conf.default.forwarding= 1
net.ipv4.conf.all.route_localnet= 1
EOF

    sysctl -p
    sysctl --system
}

# 6. 文件打开数优化
configure_limits() {
    echo -e "${GREEN}正在配置系统资源限制 (limits.conf)...${NC}"
    cat > /etc/security/limits.d/99-limits.conf << EOF
* soft    nofile          65535
* hard    nofile          65535
* soft    nproc           65535
* hard    nproc           65535
root            soft    nofile          65535
root            hard    nofile          65535
EOF
}

# 7. 日志管理优化
configure_journald() {
    echo -e "${GREEN}正在优化 Journald 日志大小限制...${NC}"
    if [ -f /etc/systemd/journald.conf ]; then
        sed -i 's/^#\?SystemMaxUse.*/SystemMaxUse=50M/' /etc/systemd/journald.conf
        sed -i 's/^#\?RuntimeMaxUse.*/RuntimeMaxUse=10M/' /etc/systemd/journald.conf
        systemctl restart systemd-journald
    fi
}

# 8. IPv4 优先配置
configure_ipv4_priority() {
    if [[ -f /etc/gai.conf ]]; then
        sed -i '/^#*precedence ::ffff:0:0\/96/d' /etc/gai.conf
        echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
        echo -e "${GREEN}IPv4 优先级已提高。${NC}"
    fi
}

# 主程序
main() {
    clear
    check_root
    check_package_manager
    
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}       Linux 系统初始化优化脚本         ${NC}"
    echo -e "${YELLOW}========================================${NC}"
    
    update_system
    install_base_tools
    configure_swap
    optimize_kernel
    configure_limits
    configure_journald
    configure_ipv4_priority
    
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  优化完成！请检查上述日志是否存在错误。${NC}"
    echo -e "${GREEN}  建议执行 'reboot' 重启系统以完全应用。${NC}"
    echo -e "${GREEN}========================================${NC}"
}

main
