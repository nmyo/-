#!/bin/bash

# 日志记录函数
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a /var/log/optimize.log
}

# 错误处理
trap 'log "脚本遇到错误，中止执行"; exit 1' ERR

# 检测操作系统类型
detect_os() {
    if [ -f /etc/redhat-release ]; then
        echo "RHEL"
    elif [ -f /etc/debian_version ]; then
        echo "Debian"
    else
        log "不支持的操作系统"
        exit 1
    fi
}

# 更新系统
update_system() {
    local os=$1
    log "更新系统"
    if [ "$os" == "RHEL" ]; then
        yum makecache
        yum install epel-release -y
        yum update -y
    elif [ "$os" == "Debian" ]; then
        apt update
        apt dist-upgrade -y
        apt autoremove --purge -y
    fi
}

# 安装 haveged
install_haveged() {
    local os=$1
    log "安装 haveged"
    if [ "$os" == "RHEL" ]; then
        yum install haveged -y
    elif [ "$os" == "Debian" ]; then
        apt install haveged -y
    fi
}

# 配置 haveged 服务
configure_haveged() {
    log "配置 haveged 服务"
    systemctl disable --now haveged
    systemctl enable --now haveged && systemctl start --now haveged
}

# 优化内核
optimize_kernel() {
    log "优化内核"
    cat > /etc/sysctl.d/99-custom.conf << EOL
# ------ 网络调优: 基本 ------
net.ipv4.tcp_timestamps=1

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
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_max_tw_buckets=55000

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
    sysctl --system
}

# 配置文件限制
configure_limits() {
    log "配置文件限制"
    cat > /etc/security/limits.conf << EOL
* soft nofile 512000
* hard nofile 512000
* soft nproc 512000
* hard nproc 512000
root soft nofile 512000
root hard nofile 512000
root soft nproc 512000
root hard nproc 512000
EOL
    ulimit -n 512000
    ulimit -u 512000
}

# 配置 systemd 日志限制
configure_journal() {
    log "配置 systemd 日志限制"
    cat > /etc/systemd/journald.conf << EOL
[Journal]
SystemMaxUse=384M
SystemMaxFileSize=128M
ForwardToSyslog=no
EOL
    systemctl restart systemd-journald
}

# 配置 IPv4 优先
configure_ipv4_priority() {
    log "配置 IPv4 优先"
    sed -i 's/#precedence ::ffff:0:0\/96  100/precedence ::ffff:0:0\/96  100/' /etc/gai.conf

    # 验证设置是否已成功应用
    ip_output=$(curl -s ip.sb)
    if [[ $ip_output =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log "IPv4 优先配置已成功应用: $ip_output"
    else
        log "IPv4 优先配置未能应用: $ip_output"
    fi
}

# 主函数执行
main() {
    OS=$(detect_os)
    update_system "$OS"
    install_haveged "$OS"
    configure_haveged
    modprobe ip_conntrack
    optimize_kernel
    configure_limits
    configure_journal
    configure_ipv4_priority

    log "优化完成"
}

main
