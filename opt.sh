#!/bin/bash

# 定义高亮颜色
GREEN='\033[0;32m'
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
                apt update
                apt dist-upgrade -y
                apt autoremove --purge -y
                ;;
            yum)
                yum makecache
                yum install epel-release -y
                yum update -y
                ;;
            dnf)
                dnf makecache
                dnf install epel-release -y
                dnf update -y
                ;;
        esac
    else
        echo -e "${GREEN}跳过系统更新${NC}"
    fi
}

# 安装必要依赖
install_dependencies() {
    case "$PACKAGE_MANAGER" in
        apt)
            apt install -y curl vnstat sudo vim nload
            ;;
        yum)
            yum install -y curl vnstat sudo vim nload
            ;;
        dnf)
            dnf install -y curl vnstat sudo vim nload
            ;;
    esac
}

# 检查并安装 haveged
install_haveged() {
    if command -v haveged &> /dev/null; then
        echo -e "${GREEN}haveged 已安装，跳过安装。${NC}"
    else
        echo -e "${GREEN}开始安装 haveged...${NC}"
        case "$PACKAGE_MANAGER" in
            apt)
                apt install haveged -y
                ;;
            yum)
                yum install haveged -y
                ;;
            dnf)
                dnf install haveged -y
                ;;
        esac
        echo -e "${GREEN}haveged 已安装完成！${NC}"

        # 启动和启用 haveged 服务
        echo -e "${GREEN}启动和启用 haveged 服务...${NC}"
        systemctl enable haveged
        systemctl start haveged
        echo -e "${GREEN}haveged 服务已启动并启用。${NC}"
    fi
}

# 配置 swap 文件
configure_swap() {
    # 检查是否安装了 virt-what 工具
    if ! command -v virt-what &> /dev/null; then
        echo -e "${GREEN}virt-what 未安装，尝试安装...${NC}"
        case "$PACKAGE_MANAGER" in
            apt)
                apt install -y virt-what
                ;;
            yum)
                yum install -y virt-what
                ;;
            dnf)
                dnf install -y virt-what
                ;;
        esac
    fi

    # 检查系统虚拟化类型
    virtualization_type=$(virt-what 2>/dev/null)

    if [[ "$virtualization_type" == *"kvm"* ]]; then
        echo -e "${GREEN}检测到系统使用 KVM 虚拟化，进行 swap 文件配置...${NC}"

        mem=$(free -m | awk '/^Mem:/{print $2}')
        swap=$(free -m | awk '/^Swap:/{print $2}')

        # 检查内存是否小于等于 512MB，并且系统中是否已存在 swap 文件
        if [ "$mem" -le 512 ] && [ "$swap" -eq 0 ]; then
            echo -e "${GREEN}内存 <= 512MB, 当前没有 swap 文件，创建 1GB 的 swap 文件...${NC}"
            fallocate -l 1G /swapfile
            chmod 600 /swapfile
            mkswap /swapfile
            swapon /swapfile
            echo '/swapfile none swap sw 0 0' | tee -a /etc/fstab
            echo -e "${GREEN}1GB 的 swap 文件已创建并启用！${NC}"
        else
            echo -e "${GREEN}系统内存 > 512MB 或已经存在 swap 文件，跳过 swap 文件配置。${NC}"
        fi
    else
        echo -e "${RED}系统不使用 KVM 虚拟化，跳过 swap 文件配置。${NC}"
    fi
}

# 优化内核
optimize_kernel() {
    cat << EOL | tee /etc/sysctl.conf
# ------ 网络调优: 基本 ------
# TTL 配置, Linux 默认 64
# net.ipv4.ip_default_ttl=64

# 参阅 RFC 1323. 应当启用.
net.ipv4.tcp_timestamps=1
# ------ END 网络调优: 基本 ------

# ------ 网络调优: 内核 Backlog 队列和缓存相关 ------
net.core.wmem_default=16384
net.core.rmem_default=262144
net.core.rmem_max=536870912
net.core.wmem_max=536870912
net.ipv4.tcp_rmem=8192 262144 536870912
net.ipv4.tcp_wmem=4096 16384 536870912
net.ipv4.tcp_adv_win_scale=-2
net.ipv4.tcp_collapse_max_bytes=6291456
net.ipv4.tcp_notsent_lowat=131072
net.core.netdev_max_backlog=10240
net.ipv4.tcp_max_syn_backlog=10240
net.core.somaxconn=8192
net.ipv4.tcp_abort_on_overflow=1
net.core.default_qdisc=fq_pie
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_window_scaling=1
net.ipv4.tcp_slow_start_after_idle=0
net.nf_conntrack_max=1000000
net.netfilter.nf_conntrack_max=1000000
net.netfilter.nf_conntrack_tcp_timeout_fin_wait=30
net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
net.netfilter.nf_conntrack_tcp_timeout_close_wait=15
net.netfilter.nf_conntrack_tcp_timeout_established=300
net.ipv4.netfilter.ip_conntrack_tcp_timeout_established=7200
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_max_tw_buckets=55000
# ------ END 网络调优: 内核 Backlog 队列和缓存相关 ------

# ------ 网络调优: 其他 ------
net.ipv4.tcp_sack=1
net.ipv4.tcp_fack=1
net.ipv4.tcp_syn_retries=3
net.ipv4.tcp_synack_retries=3
net.ipv4.tcp_retries2=5
net.ipv4.tcp_syncookies=0
net.ipv4.conf.default.rp_filter=2
net.ipv4.conf.all.rp_filter=2
net.ipv4.tcp_fin_timeout=10
net.ipv4.tcp_no_metrics_save=1
net.unix.max_dgram_qlen=1024
net.ipv4.route.gc_timeout=100
net.ipv4.tcp_mtu_probing=1
net.ipv4.conf.all.log_martians=1
net.ipv4.conf.default.log_martians=1
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.accept_source_route=0
net.ipv4.tcp_keepalive_time=300
net.ipv4.tcp_keepalive_probes=2
net.ipv4.tcp_keepalive_intvl=2
net.ipv4.tcp_max_orphans=262144
net.ipv4.neigh.default.gc_thresh1=128
net.ipv4.neigh.default.gc_thresh2=512
net.ipv4.neigh.default.gc_thresh3=4096
net.ipv4.neigh.default.gc_stale_time=120
net.ipv4.conf.default.arp_announce=2
net.ipv4.conf.lo.arp_announce=2
net.ipv4.conf.all.arp_announce=2
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding=1
# ------ END 网络调优: 其他 ------

# ------ 内核调优 ------
kernel.panic=1
kernel.pid_max=32768
kernel.shmmax=4294967296
kernel.shmall=1073741824
kernel.core_pattern=core_%e
vm.panic_on_oom=1
vm.vfs_cache_pressure=250
vm.swappiness=10
vm.dirty_ratio=10
vm.overcommit_memory=1
fs.file-max=1048575
fs.inotify.max_user_instances=8192
fs.inotify.max_user_watches=8192
kernel.sysrq=1
vm.zone_reclaim_mode=0
EOL
    sysctl -p
}

# 配置文件限制
configure_limits() {
    cat << EOL | tee /etc/security/limits.conf
* soft nofile 512000
* hard nofile 512000
* soft nproc 512000
* hard nproc 512000
root soft nofile 512000
root hard nofile 512000
root soft nproc 512000
root hard nproc 512000
EOL
}

# 配置 systemd 日志限制
configure_journal() {
    cat << EOL | tee /etc/systemd/journald.conf
[Journal]
SystemMaxUse=384M
SystemMaxFileSize=128M
ForwardToSyslog=no
EOL
}

# 配置 IPv4 优先
configure_ipv4_priority() {
    # 检查是否存在有效的 IPv4 地址
    if ip -4 addr show | grep -E 'inet ' | grep -vE '127.0.0.1|::' > /dev/null; then
        echo -e "${GREEN}检测到有效的 IPv4 地址，配置 IPv4 优先级。${NC}"

        # 备份原始配置文件
        cp /etc/gai.conf /etc/gai.conf.bak

        # 设置 IPv4 优先
        if grep -q '^precedence ::ffff:0:0/96  100' /etc/gai.conf; then
            echo -e "${GREEN}IPv4 优先设置已经存在。${NC}"
        else
            sed -i 's/#precedence ::ffff:0:0\/96  100/precedence ::ffff:0:0\/96  100/' /etc/gai.conf
            echo -e "${GREEN}IPv4 优先设置已应用。${NC}"
        fi

        # 验证设置是否已成功应用
        ip_output=$(curl -s ip.sb)
        if [[ $ip_output =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo -e "${GREEN}IPv4 优先配置已成功应用: $ip_output${NC}"
        else
            echo -e "${RED}IPv4 优先配置未能应用: $ip_output${NC}"
        fi
    else
        echo -e "${RED}未检测到有效的 IPv4 地址，跳过 IPv4 优先级配置。${NC}"
    fi
}

# 主函数
main() {
    check_package_manager
    update_system
    install_dependencies
    install_haveged
    configure_swap
    optimize_kernel
    configure_limits
    configure_journal
    configure_ipv4_priority
}

main "$@"
