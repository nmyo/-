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

# 3. 基础依赖与 haveged (熵池优化)
install_base_tools() {
    echo -e "${GREEN}正在安装基础依赖工具...${NC}"
    local packages="curl vnstat sudo vim nload lsof dnsutils btop jq virt-what haveged"
    
    # RHEL 系需要先安装 epel-release
    if [[ "$PACKAGE_MANAGER" != "apt" ]]; then
        pkg_install epel-release
    fi
    
    pkg_install $packages
    systemctl enable --now haveged
}

# 4. Swap 自动配置 (仅针对 KVM/物理机)
configure_swap() {
    local virtualization_type=$(virt-what 2>/dev/null)
    # 如果是 OpenVZ 或 LXC，通常无法在容器内挂载 Swap
    if [[ "$virtualization_type" == *"lxc"* || "$virtualization_type" == *"openvz"* ]]; then
        echo -e "${YELLOW}检测到容器虚拟化 ($virtualization_type)，跳过 Swap 配置。${NC}"
        return
    fi

    local mem=$(free -m | awk '/^Mem:/{print $2}')
    local swap=$(free -m | awk '/^Swap:/{print $2}')

    if [ "$swap" -eq 0 ]; then
        echo -e "${GREEN}检测到未配置 Swap，正在创建 1GB 虚拟内存...${NC}"
        # 使用 fallocate 更快，如果不支持则回退到 dd
        fallocate -l 1G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=1024
        chmod 600 /swapfile
        mkswap /swapfile && swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        echo -e "${GREEN}Swap 配置完成。${NC}"
    else
        echo -e "${GREEN}系统已存在 Swap ($swap MB)，跳过。${NC}"
    fi
}

# 5. 内核参数深度优化 (BBR/网络/内存)
optimize_kernel() {
    echo -e "${GREEN}正在配置内核参数 (sysctl)...${NC}"
    
    # 智能选择队列算法: 优先使用 cake, 否则使用 fq
    local qdisc="fq"
    if sysctl net.core.default_qdisc | grep -q "cake"; then qdisc="cake"; fi

    # 写入独立的配置文件，不污染主文件
    cat > /etc/sysctl.d/99-custom-optimize.conf << EOF
# TCP 拥塞控制 BBR
net.core.default_qdisc=$qdisc
net.ipv4.tcp_congestion_control=bbr

# 提高并发连接限制
net.ipv4.tcp_max_syn_backlog=8192
net.ipv4.tcp_max_tw_buckets=5000
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15
net.ipv4.tcp_keepalive_time=600

# 扩大 TCP 接收/发送缓冲区 (适合高速网络)
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864

# 启用转发
net.ipv4.ip_forward=1
net.ipv4.conf.all.route_localnet=1

# 内存优化
vm.swappiness=10
vm.vfs_cache_pressure=50
vm.overcommit_memory=1

# 其他网络增强
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_mtu_probing=1
EOF
    sysctl -p /etc/sysctl.d/99-custom-optimize.conf &>/dev/null
    sysctl --system &>/dev/null
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

# 7. 日志管理优化 (防止日志占满硬盘)
configure_journald() {
    echo -e "${GREEN}正在优化 Journald 日志大小限制...${NC}"
    sed -i 's/^#\?SystemMaxUse.*/SystemMaxUse=50M/' /etc/systemd/journald.conf
    sed -i 's/^#\?RuntimeMaxUse.*/RuntimeMaxUse=10M/' /etc/systemd/journald.conf
    systemctl restart systemd-journald
}

# 8. IPv4 优先配置
configure_ipv4_priority() {
    if [[ -f /etc/gai.conf ]]; then
        sed -i '/^#*precedence ::ffff:0:0\/96/d' /etc/gai.conf
        echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
        echo -e "${GREEN}IPv4 优先级已提高。${NC}"
    fi
}

# 主程序逻辑
main() {
    check_root
    check_package_manager
    
    echo -e "${YELLOW}>>> 开始系统初始化优化 <<<${NC}"
    
    update_system
    install_base_tools
    configure_swap
    optimize_kernel
    configure_limits
    configure_journald
    configure_ipv4_priority
    
    echo -e "${GREEN}====================================${NC}"
    echo -e "${GREEN}  所有优化已完成！建议重启系统。  ${NC}"
    echo -e "${GREEN}====================================${NC}"
}

main
