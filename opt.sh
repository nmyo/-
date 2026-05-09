#!/bin/bash

# ====================================================
# Linux 系统初始化与优化脚本（修正版 v1.1）
# ====================================================

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

# ================================
# 1. 权限与包管理器检查
# ================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误: 必须以 root 权限运行此脚本。${NC}"
        exit 1
    fi
}

check_package_manager() {
    if command -v apt &> /dev/null; then
        PACKAGE_MANAGER="apt"
        UPDATE_CMD="apt update"
        UPGRADE_CMD="apt dist-upgrade -y"
        INSTALL_CMD="apt install -y"
    elif command -v dnf &> /dev/null; then
        PACKAGE_MANAGER="dnf"
        UPDATE_CMD="dnf makecache"
        UPGRADE_CMD="dnf upgrade -y"
        INSTALL_CMD="dnf install -y"
    elif command -v yum &> /dev/null; then
        PACKAGE_MANAGER="yum"
        UPDATE_CMD="yum makecache"
        UPGRADE_CMD="yum update -y"
        INSTALL_CMD="yum install -y"
    else
        echo -e "${RED}错误: 未检测到支持的包管理器 (apt, dnf, yum)${NC}"
        exit 1
    fi
}

# ================================
# 2. 系统更新
# ================================
update_system() {
    local prompt_text
    prompt_text=$(echo -e "${YELLOW}---> 是否要更新系统软件包？(y/n): ${NC}")
    read -p "$prompt_text" update_choice
    
    if [[ "$update_choice" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}正在更新系统，请稍候...${NC}"
        $UPDATE_CMD
        $UPGRADE_CMD
    else
        echo -e "${GREEN}跳过系统更新。${NC}"
    fi
}

# ================================
# 3. 基础依赖安装
# ================================
install_base_tools() {
    echo -e "${GREEN}正在安装基础依赖工具...${NC}"
    local packages="curl vnstat sudo vim nload lsof dnsutils btop jq virt-what haveged"

    if [[ "$PACKAGE_MANAGER" != "apt" ]]; then
        rpm -q epel-release &> /dev/null || $INSTALL_CMD epel-release
    fi

    $INSTALL_CMD $packages
    systemctl enable --now haveged &> /dev/null
}

# ================================
# 4. Swap 自动配置
# ================================
configure_swap() {
    local virt_type
    virt_type=$(virt-what 2>/dev/null)
    if [[ "$virt_type" == "lxc" || "$virt_type" == *"openvz"* ]]; then
        echo -e "${YELLOW}检测到容器虚拟化 ($virt_type)，跳过 Swap 配置。${NC}"
        return
    fi

    local current_swap
    current_swap=$(free -m | awk '/^Swap:/{print $2}')
    if [[ "$current_swap" -eq 0 ]]; then
        echo -e "${GREEN}正在创建 2GB 虚拟内存 (Swap)...${NC}"
        fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
        chmod 600 /swapfile
        mkswap /swapfile > /dev/null
        swapon /swapfile
        if ! grep -q "/swapfile" /etc/fstab; then
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi
    else
        echo -e "${GREEN}系统已存在 Swap ($current_swap MB)，跳过。${NC}"
    fi
}

# ================================
# 5. 内核参数深度优化
# ================================
optimize_kernel() {
    echo -e "${GREEN}正在配置内核参数 (/etc/sysctl.d/99-sysctl-optimize.conf)...${NC}"
    
    [ -f /etc/sysctl.conf ] && cp /etc/sysctl.conf /etc/sysctl.conf.bak

    cat > /etc/sysctl.d/99-sysctl-optimize.conf << 'EOF'
# 文件句柄限制
fs.file-max = 6815744

# 网络队列与连接优化
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 8192
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_abort_on_overflow = 1

# BBR 拥塞控制
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# TCP 特性优化
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 2
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_fin_timeout = 30

# 高速大带宽缓冲区调整
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864

# 端口范围
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_timestamps = 1

# 转发与路由
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
vm.overcommit_memory = 1
EOF

    sysctl --system > /dev/null
}

# ================================
# 6. 文件打开数优化
# ================================
configure_limits() {
    echo -e "${GREEN}正在配置系统资源限制 (limits.conf)...${NC}"
    cat > /etc/security/limits.d/99-limits.conf << EOF
* soft    nofile          1048576
* hard    nofile          1048576
* soft    nproc           65535
* hard    nproc           65535
root            soft    nofile          1048576
root            hard    nofile          1048576
EOF
}

# ================================
# 7. 日志管理优化
# ================================
configure_journald() {
    echo -e "${GREEN}正在优化 Journald 日志大小限制...${NC}"
    local journal_conf="/etc/systemd/journald.conf"
    if [[ -f "$journal_conf" ]]; then
        grep -q "^SystemMaxUse" "$journal_conf" || echo "SystemMaxUse=50M" >> "$journal_conf"
        grep -q "^RuntimeMaxUse" "$journal_conf" || echo "RuntimeMaxUse=10M" >> "$journal_conf"
        systemctl restart systemd-journald
    fi
}

# ================================
# 8. IPv4 优先配置
# ================================
configure_ipv4_priority() {
    local gai_conf="/etc/gai.conf"
    if [[ -f "$gai_conf" ]]; then
        if ! grep -q "::ffff:0:0/96" "$gai_conf"; then
            echo "precedence ::ffff:0:0/96  100" >> "$gai_conf"
            echo -e "${GREEN}IPv4 优先级已提高。${NC}"
        fi
    fi
}

# ================================
# 主程序
# ================================
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

main "$@"
