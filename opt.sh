cat << 'EOF' > /root/opt.sh
#!/bin/bash

# 定义高亮颜色
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # 没有颜色

# 检测包管理器
check_package_manager() {
    if command -v apt &> /dev/null; then
        PACKAGE_MANAGER="apt"
    elif command -v yum &> /dev/null; then
        PACKAGE_MANAGER="yum"
    elif command -v dnf &> /dev/null; then
        PACKAGE_MANAGER="dnf"
    else
        echo -e "${RED}错误: 未检测到支持的包管理器 (apt, yum, dnf)${NC}"
        exit 1
    fi
}

# 更新系统
update_system() {
    echo -e "${GREEN}是否要更新系统？(y/n)${NC}"
    read -r update_choice
    if [[ "$update_choice" =~ ^[Yy]$ ]]; then
        case "$PACKAGE_MANAGER" in
            apt)
                apt update && apt dist-upgrade -y && apt autoremove --purge -y
                ;;
            yum)
                yum makecache && yum update -y
                ;;
            dnf)
                dnf makecache && dnf update -y
                ;;
        esac
    else
        echo -e "${GREEN}跳过系统更新${NC}"
    fi
}

# 安装必要依赖
install_dependencies() {
    local packages="curl vnstat sudo vim nload lsof dnsutils btop jq"
    case "$PACKAGE_MANAGER" in
        apt)
            apt install -y $packages
            ;;
        yum)
            yum install -y $packages epel-release
            ;;
        dnf)
            dnf install -y $packages epel-release
            ;;
    esac
}

# 检查并安装 haveged
install_haveged() {
    if ! command -v haveged &> /dev/null; then
        echo -e "${GREEN}安装 haveged...${NC}"
        case "$PACKAGE_MANAGER" in
            apt) apt install -y haveged ;;
            yum) yum install -y haveged ;;
            dnf) dnf install -y haveged ;;
        esac
        systemctl enable --now haveged
        echo -e "${GREEN}haveged 安装并启动完成！${NC}"
    else
        echo -e "${GREEN}haveged 已安装，跳过安装。${NC}"
    fi
}

# 配置 swap 文件
configure_swap() {
    if ! command -v virt-what &> /dev/null; then
        echo -e "${GREEN}virt-what 未安装，尝试安装...${NC}"
        case "$PACKAGE_MANAGER" in
            apt) apt install -y virt-what ;;
            yum) yum install -y virt-what ;;
            dnf) dnf install -y virt-what ;;
        esac
    fi

    local virtualization_type=$(virt-what 2>/dev/null)
    if [[ "$virtualization_type" == *"kvm"* ]]; then
        echo -e "${GREEN}检测到 KVM 虚拟化，开始配置 swap 文件...${NC}"
        local mem=$(free -m | awk '/^Mem:/{print $2}')
        local swap=$(free -m | awk '/^Swap:/{print $2}')
        if [ "$mem" -le 512 ] && [ "$swap" -eq 0 ]; then
            dd if=/dev/zero of=/swapfile bs=1M count=1024 && chmod 600 /swapfile
            mkswap /swapfile && swapon /swapfile
            echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
            echo -e "${GREEN}1GB swap 文件已创建并启用！${NC}"
        else
            echo -e "${GREEN}内存 > 512MB 或已存在 swap 文件，跳过配置。${NC}"
        fi
    else
        echo -e "${RED}系统未使用 KVM 虚拟化，跳过 swap 文件配置。${NC}"
    fi
}

# 优化内核
optimize_kernel() {
    cat << EOL | tee /etc/sysctl.conf
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_ecn=0
net.ipv4.tcp_frto=0
net.ipv4.tcp_mtu_probing=0
net.ipv4.tcp_rfc1337=0
net.ipv4.tcp_sack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_adv_win_scale=1
net.ipv4.tcp_moderate_rcvbuf=1
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.ipv4.tcp_rmem=4096 87380 33554432
net.ipv4.tcp_wmem=4096 16384 33554432
net.ipv4.udp_rmem_min=8192
net.ipv4.udp_wmem_min=8192
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.conf.all.route_localnet=1
net.ipv4.ip_forward=1
net.ipv4.conf.all.forwarding=1
net.ipv4.conf.default.forwarding=1
EOL
    sysctl --system
    echo -e "${GREEN}内核优化配置已完成。${NC}"
}

# 配置系统限制
configure_limits() {
    cat << EOL | tee /etc/security/limits.conf
root     hard   nofile    1000000
root     soft   nproc     1000000
root     hard   nproc     1000000
root     soft   core      1000000
root     hard   core      1000000
root     hard   memlock   unlimited
root     soft   memlock   unlimited

*     soft   nofile    1000000
*     hard   nofile    1000000
*     soft   nproc     1000000
*     hard   nproc     1000000
*     soft   core      1000000
*     hard   core      1000000
*     hard   memlock   unlimited
*     soft   memlock   unlimited
EOL
}

# 配置 journald
configure_journald() {
    cat << EOL | tee /etc/systemd/journald.conf
[Journal]
SystemMaxUse=1G
RuntimeMaxUse=512M
SystemMaxFileSize=50M
RuntimeMaxFileSize=20M
EOL
    systemctl restart systemd-journald
    echo -e "${GREEN}journald 配置已完成。${NC}"
}

# 配置 IPv4 优先
configure_ipv4_priority() {
    if ip -4 addr show | grep -E 'inet ' | grep -vE '127.0.0.1|::' > /dev/null; then
        echo -e "${GREEN}检测到有效的 IPv4 地址，配置 IPv4 优先级。${NC}"
        cp /etc/gai.conf /etc/gai.conf.bak
        sed -i '/^#*precedence ::ffff:0:0\/96/d' /etc/gai.conf
        echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
        echo -e "${GREEN}IPv4 优先设置已强制写入。${NC}"
    else
        echo -e "${RED}未检测到有效的 IPv4 地址，跳过 IPv4 配置。${NC}"
    fi
}

# 主程序
main() {
    check_package_manager
    update_system
    install_dependencies
    install_haveged
    configure_swap
    optimize_kernel
    configure_limits
    configure_journald
    configure_ipv4_priority
}

main
EOF

chmod +x /root/opt.sh && bash /root/opt.sh
