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
            apt install -y curl vnstat sudo vim nload lsof dnsutils btop
            ;;
        yum)
            yum install -y curl epel-release vnstat sudo vim nload lsof bind-utils btop
            ;;
        dnf)
            dnf install -y curl epel-release vnstat sudo vim nload lsof bind-utils btop
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
            
            # 使用 dd 创建 swap 文件
            dd if=/dev/zero of=/swapfile bs=1M count=1024
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
# 有条件建议依据实测结果调整相关数值
# 缓冲区相关配置均和内存相关
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
# 流控和拥塞控制相关调优
net.core.default_qdisc=fq_pie
net.ipv4.tcp_congestion_control=bbr
# TCP 自动窗口
# 要支持超过 64KB 的 TCP 窗口必须启用
net.ipv4.tcp_window_scaling=1
# 开启后, TCP 拥塞窗口会在一个 RTO 时间
# 空闲之后重置为初始拥塞窗口 (CWND) 大小.
# 大部分情况下, 尤其是大流量长连接, 设置为 0.
# 对于网络情况时刻在相对剧烈变化的场景, 设置为 1.
net.ipv4.tcp_slow_start_after_idle=0
# nf_conntrack 调优
net.nf_conntrack_max=1000000
net.netfilter.nf_conntrack_max=1000000
net.netfilter.nf_conntrack_tcp_timeout_fin_wait=30
net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
net.netfilter.nf_conntrack_tcp_timeout_close_wait=15
net.netfilter.nf_conntrack_tcp_timeout_established=300
net.ipv4.netfilter.ip_conntrack_tcp_timeout_established=7200
# TIME-WAIT 状态调优
# 只对客户端生效, 服务器连接上游时也认为是客户端
net.ipv4.tcp_tw_reuse=1
# 系统同时保持TIME_WAIT套接字的最大数量
# 如果超过这个数字 TIME_WAIT 套接字将立刻被清除
net.ipv4.tcp_max_tw_buckets=55000
# ------ END 网络调优: 内核 Backlog 队列和缓存相关 ------

# ------ 网络调优: 其他 ------
# 启用选择应答
# 对于广域网通信应当启用
net.ipv4.tcp_sack=1
# 启用转发应答
# 对于广域网通信应当启用
net.ipv4.tcp_fack=1
# TCP SYN 连接超时重传次数
net.ipv4.tcp_syn_retries=3
net.ipv4.tcp_synack_retries=3
# TCP SYN 连接超时时间, 设置为 5 约为 30s
net.ipv4.tcp_retries2=5
# 开启 SYN 洪水攻击保护
# 勿听信所谓“安全优化教程”而无脑开启
net.ipv4.tcp_syncookies=0
# 开启反向路径过滤
# Aliyun 负载均衡实例后端的 ECS 需要设置为 0
net.ipv4.conf.default.rp_filter=2
net.ipv4.conf.all.rp_filter=2
# 减少处于 FIN-WAIT-2 连接状态的时间使系统可以处理更多的连接
net.ipv4.tcp_fin_timeout=10
# 默认情况下一个 TCP 连接关闭后, 把这个连接曾经有的参数保存到dst_entry中
# 只要 dst_entry 没有失效,下次新建立相同连接的时候就可以使用保存的参数来初始化这个连接.通常情况下是关闭的
net.ipv4.tcp_no_metrics_save=1
# unix socket 最大队列
net.unix.max_dgram_qlen=1024
# 路由缓存刷新频率
net.ipv4.route.gc_timeout=100
# 启用 MTU 探测，在链路上存在 ICMP 黑洞时候有用（大多数情况是这样）
net.ipv4.tcp_mtu_probing = 1
# 开启并记录欺骗, 源路由和重定向包
net.ipv4.conf.all.log_martians=1
net.ipv4.conf.default.log_martians=1
# 处理无源路由的包
net.ipv4.conf.all.accept_source_route=0
net.ipv4.conf.default.accept_source_route=0
# TCP KeepAlive 调优
# 最大闲置时间
net.ipv4.tcp_keepalive_time=300
# 最大失败次数, 超过此值后将通知应用层连接失效
net.ipv4.tcp_keepalive_probes=2
# 发送探测包的时间间隔
net.ipv4.tcp_keepalive_intvl=2
# 系统所能处理不属于任何进程的TCP sockets最大数量
net.ipv4.tcp_max_orphans=262144
# arp_table的缓存限制优化
net.ipv4.neigh.default.gc_thresh1=128
net.ipv4.neigh.default.gc_thresh2=512
net.ipv4.neigh.default.gc_thresh3=4096
net.ipv4.neigh.default.gc_stale_time=120
net.ipv4.conf.default.arp_announce=2
net.ipv4.conf.lo.arp_announce=2
net.ipv4.conf.all.arp_announce=2
# ------ END 网络调优: 其他 ------

# ------ 内核调优 ------
# 内核 Panic 后 1 秒自动重启
kernel.panic=1
# 允许更多的PIDs, 减少滚动翻转问题
kernel.pid_max=32768
# 内核所允许的最大共享内存段的大小（bytes）
kernel.shmmax=4294967296
# 在任何给定时刻, 系统上可以使用的共享内存的总量（pages）
kernel.shmall=1073741824
# 设定程序core时生成的文件名格式
kernel.core_pattern=core_%e
# 当发生oom时, 自动转换为panic
vm.panic_on_oom=1
# 表示强制Linux VM最低保留多少空闲内存（Kbytes）
# vm.min_free_kbytes=1048576
# 该值高于100, 则将导致内核倾向于回收directory和inode cache
vm.vfs_cache_pressure=250
# 表示系统进行交换行为的程度, 数值（0-100）越高, 越可能发生磁盘交换
vm.swappiness=10
# 仅用10%做为系统cache
vm.dirty_ratio=10
vm.overcommit_memory=1
# 增加系统文件描述符限制
# Fix error: too many open files
fs.file-max=2097152
fs.inotify.max_user_instances=8192
fs.inotify.max_user_instances=8192
# 内核响应魔术键
kernel.sysrq=1
# 当某个节点可用内存不足时, 系统会倾向于从其他节点分配内存. 对 Mongo/Redis 类 cache 服务器友好
vm.zone_reclaim_mode=0

EOL

    sysctl --system  # 自动应用配置
    echo -e "${GREEN}内核优化配置已完成，自动应用配置。${NC}"
}

# 配置端口转发加速
configure_port_forwarding_acceleration() {
    echo -e "${GREEN}是否开启端口转发加速？此配置只建议在中转机上使用(y/n)${NC}"
    read -r acceleration_choice
    if [[ "$acceleration_choice" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}配置端口转发加速...${NC}"
        # 添加端口转发加速配置
        cat << EOL | tee /etc/sysctl.d/99-port-forwarding.conf
net.ipv4.ip_forward=1
net.ipv4.conf.all.forwarding=1
net.ipv4.conf.default.forwarding=1
net.ipv4.conf.all.proxy_arp=1
net.ipv4.conf.default.proxy_arp=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2

EOL
        sysctl --system
        echo -e "${GREEN}端口转发加速配置完成。${NC}"
    else
        echo -e "${GREEN}跳过端口转发加速配置。${NC}"
    fi
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

# 主程序
main() {
    check_package_manager
    update_system
    install_dependencies
    install_haveged
    configure_swap
    optimize_kernel
    configure_port_forwarding_acceleration
    configure_limits
    configure_journald
    configure_ipv4_priority
}

main
