#!/bin/bash

# 检查是否以 root 权限运行
if [[ $EUID -ne 0 ]]; then
   echo "此脚本必须以 root 权限运行" 
   exit 1
fi

# 开始清理前的磁盘空间
start_space=$(df / | awk 'NR==2 {print $4}')

# 更新依赖
echo "正在更新依赖..."
apt-get update &> /dev/null
apt-get install -y deborphan &> /dev/null

# 删除旧内核
echo "正在删除未使用的内核..."
current_kernel=$(uname -r)
kernel_packages=$(dpkg -l | grep linux-image | awk '{print $2}' | grep -v "$current_kernel")
if [ -n "$kernel_packages" ]; then
    echo "找到旧内核，正在删除：$kernel_packages"
    apt-get -y remove --purge $kernel_packages &> /dev/null
    update-grub &> /dev/null
else
    echo "没有旧内核需要删除。"
fi

# 清理系统日志文件
echo "正在清理系统日志文件..."
find /var/log -type f -name "*.log" -delete &> /dev/null
find /root /home -type f -name "*.log" -delete &> /dev/null

# 清理缓存目录
echo "正在清理缓存目录..."
rm -rf /tmp/* /var/tmp/* /home/*/.cache/* /root/.cache/* &> /dev/null

# 清理 Docker
if command -v docker &> /dev/null
then
    echo "正在清理 Docker 镜像、容器和卷..."
    docker system prune -a -f --volumes &> /dev/null
fi

# 清理孤立包
echo "正在清理孤立包..."
deborphan --guess-all | xargs -r apt-get -y remove --purge &> /dev/null

# 清理包管理器缓存
echo "正在清理包管理器缓存..."
apt-get autoremove -y &> /dev/null
apt-get clean &> /dev/null

# 结束时的磁盘空间
end_space=$(df / | awk 'NR==2 {print $4}')

# 清理空间
cleared_space=$((start_space - end_space))
echo "系统清理完成，已释放 $((cleared_space / 1024))M 空间！"
