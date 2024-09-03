#!/bin/bash

# 检查系统类型
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VERSION_ID=$VERSION_ID
else
    echo "无法检测到操作系统。"
    exit 1
fi

# 检查软件包是否已安装的函数
is_installed() {
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        dpkg -l | grep -q "$1"
    elif [[ "$OS" == "centos" || "$OS" == "almalinux" ]]; then
        rpm -q "$1" > /dev/null 2>&1
    else
        echo "不支持的操作系统。"
        exit 1
    fi
}

# 安装必要的软件包
install_packages() {
    if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
        sudo apt-get update && sudo apt-get install -y lsb-release vim unzip curl wget net-tools sudo gnupg || { echo "软件包安装失败，脚本退出。"; exit 1; }
    elif [[ "$OS" == "centos" || "$OS" == "almalinux" ]]; then
        sudo yum install -y epel-release
        sudo yum install -y redhat-lsb-core vim unzip curl wget net-tools sudo gnupg2
    else
        echo "不支持的操作系统: $OS"
        exit 1
    fi
}

# 配置 Debian 源
configure_debian_sources() {
    DEBIAN_VERSION=$(lsb_release -cs)  # 使用小写字母的版本代号
    if [ "$DEBIAN_VERSION" = "bullseye" ]; then
        echo "deb http://deb.debian.org/debian bullseye-backports main" | sudo tee /etc/apt/sources.list.d/backports.list
    elif [ "$DEBIAN_VERSION" = "bookworm" ]; then
        echo "deb http://deb.debian.org/debian bookworm-backports main" | sudo tee /etc/apt/sources.list.d/backports.list
    else
        echo "不支持的 Debian 版本: $DEBIAN_VERSION"
        exit 1
    fi
}

# 安装内核的函数
install_kernel() {
    echo "请选择要执行的操作："
    echo "1. 安装 Cloud 内核"
    echo "2. 安装普通内核"
    echo "3. 安装 Xen 内核"
    echo "4. 安装 XanMod 内核"
    echo "5. 卸载 XanMod 内核"
    echo "6. 退出"
    read -p "输入数字选择 (1、2、3、4、5 或 6): " KERNEL_CHOICE

    if [[ "$KERNEL_CHOICE" = "1" ]]; then
        if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
            sudo apt -t ${DEBIAN_VERSION}-backports install -y linux-image-cloud-$(dpkg --print-architecture) linux-headers-cloud-$(dpkg --print-architecture) --install-recommends
        elif [[ "$OS" == "centos" || "$OS" == "almalinux" ]]; then
            sudo yum install -y kernel-cloud kernel-cloud-devel
        else
            echo "不支持的操作系统: $OS"
            exit 1
        fi
    elif [[ "$KERNEL_CHOICE" = "2" ]]; then
        if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
            sudo apt -t ${DEBIAN_VERSION}-backports install -y linux-image-$(dpkg --print-architecture) linux-headers-$(dpkg --print-architecture) --install-recommends
        elif [[ "$OS" == "centos" || "$OS" == "almalinux" ]]; then
            sudo yum install -y kernel kernel-devel
        else
            echo "不支持的操作系统: $OS"
            exit 1
        fi
    elif [[ "$KERNEL_CHOICE" = "3" ]]; then
        if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
            sudo apt -t ${DEBIAN_VERSION}-backports install -y linux-image-xen-$(dpkg --print-architecture) linux-headers-xen-$(dpkg --print-architecture) --install-recommends
        elif [[ "$OS" == "centos" || "$OS" == "almalinux" ]]; then
            sudo yum install -y kernel-xen kernel-xen-devel
        else
            echo "不支持的操作系统: $OS"
            exit 1
        fi
    elif [[ "$KERNEL_CHOICE" = "4" ]]; then
        if [[ "$OS" != "ubuntu" && "$OS" != "debian" && "$OS" != "centos" && "$OS" != "almalinux" ]]; then
            echo "XanMod 内核仅支持 Debian、Ubuntu、CentOS 和 AlmaLinux。"
            exit 1
        fi

        # 添加 XanMod 仓库 GPG 密钥和仓库
        wget -qO - https://dl.xanmod.org/archive.key | sudo gpg --dearmor -o /usr/share/keyrings/xanmod-archive-keyring.gpg || { echo "添加 GPG 密钥失败，脚本退出。"; exit 1; }
        echo 'deb [signed-by=/usr/share/keyrings/xanmod-archive-keyring.gpg] http://deb.xanmod.org releases main' | sudo tee /etc/apt/sources.list.d/xanmod-release.list || { echo "添加仓库失败，脚本退出。"; exit 1; }

        # 判断 CPU 架构
        VERSION_OUTPUT=$(awk -f <(wget -O - https://dl.xanmod.org/check_x86-64_psabi.sh))
        if [[ $VERSION_OUTPUT == *"x86-64-v4"* ]]; then
            XANMOD_VERSION="linux-xanmod-x64v4"
        elif [[ $VERSION_OUTPUT == *"x86-64-v3"* ]]; then
            XANMOD_VERSION="linux-xanmod-x64v3"
        elif [[ $VERSION_OUTPUT == *"x86-64-v2"* ]]; then
            XANMOD_VERSION="linux-xanmod-x64v2"
        elif [[ $VERSION_OUTPUT == *"x86-64-v1"* ]]; then
            XANMOD_VERSION="linux-xanmod-x64v1"
        else
            echo "无法识别的 CPU 架构，脚本退出。"
            exit 1
        fi

        echo "将安装的 XanMod 内核版本: $XANMOD_VERSION"

        # 提示用户选择是否安装相应版本的 XanMod 内核
        read -p "是否要安装 $XANMOD_VERSION？(y/n) " choice
        case "$choice" in
            y|Y )
                # 更新包列表并安装相应版本的 XanMod 内核
                sudo apt update || { echo "更新包列表失败，脚本退出。"; exit 1; }
                sudo apt install -y $XANMOD_VERSION || { echo "安装 $XANMOD_VERSION 失败，脚本退出。"; exit 1; }
                ;;
            n|N )
                echo "取消安装 $XANMOD_VERSION。"
                exit 0
                ;;
            * )
                echo "无效的输入，脚本退出。"
                exit 1
                ;;
        esac
    elif [[ "$KERNEL_CHOICE" = "5" ]]; then
        if [[ "$OS" != "ubuntu" && "$OS" != "debian" && "$OS" != "centos" && "$OS" != "almalinux" ]]; then
            echo "XanMod 内核卸载仅支持 Debian、Ubuntu、CentOS 和 AlmaLinux。"
            exit 1
        fi

        # 查找已安装的 XanMod 内核
        echo "正在查找已安装的 XanMod 内核版本..."
        xanmod_kernels=$(dpkg --list | grep xanmod | awk '{print $2}')

        # 检查是否找到了任何 XanMod 内核
        if [ -z "$xanmod_kernels" ]; then
            echo "未找到已安装的 XanMod 内核。"
            exit 0
        fi

        # 列出找到的 XanMod 内核
        echo "以下 XanMod 内核将被卸载:"
        echo "$xanmod_kernels"

        # 提示用户确认卸载
        read -p "是否确认卸载这些内核？[y/N]: " confirm
        if [[ $confirm != [yY] ]]; then
            echo "操作已取消。"
            exit 1
        fi

        # 卸载 XanMod 内核
        echo "正在卸载 XanMod 内核..."
        for kernel in $xanmod_kernels; do
            sudo apt remove --purge -y $kernel
            if [ $? -eq 0 ]; then
                echo "$kernel 已成功卸载。"
            else
                echo "卸载 $kernel 失败。"
            fi
        done
    elif [[ "$KERNEL_CHOICE" = "6" ]]; then
        echo "退出。"
        exit 0
    else
        echo "无效的选择。"
        exit 1
    fi

    # 提示用户是否需要重启
    read -p "是否需要重启系统？[y/N]: " reboot_choice
    if [[ $reboot_choice == [yY] ]]; then
        sudo reboot
    else
        echo "请记得手动重启系统以应用内核更改。"
    fi
}

# 主脚本逻辑
install_packages

if [[ "$OS" == "debian" ]]; then
    configure_debian_sources
fi

install_kernel

# 配置 Debian 源
if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    configure_debian_sources
fi

# 执行内核安装操作
install_kernel

# 更新 GRUB 配置
update_grub

# 提示用户是否重启系统
if [[ "$KERNEL_CHOICE" != "5" && "$KERNEL_CHOICE" != "6" ]]; then
    echo "内核操作完成。"
    read -p "是否现在重启系统以应用新内核？ (y/n): " REBOOT_CHOICE

    if [[ "$REBOOT_CHOICE" == "y" || "$REBOOT_CHOICE" == "Y" ]]; then
        echo "正在重启系统以应用新内核..."
        sudo reboot
    else
        echo "请记住稍后手动重启系统以应用新内核。"
    fi
fi
EOF
