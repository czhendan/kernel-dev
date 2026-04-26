#!/bin/bash

# ================= 核心配置区 =================
WORKSPACE="$HOME/kernel-dev"
KERNEL_DIR="$WORKSPACE/linux-6.19.8"
KERNEL_BZIMAGE="$KERNEL_DIR/arch/x86/boot/bzImage"
ROOTFS_DIR="$WORKSPACE/rootfs"
ROOTFS_IMG="$WORKSPACE/rootfs.cpio.gz"
SHARED_DIR="$WORKSPACE/share"
LOG_FILE="$SHARED_DIR/kernel_crash.log"

QEMU_MEM="2G"
QEMU_CPU="4"
# 网络与 9P 共享文件夹映射参数
NETWORK_OPT="-nic user,model=e1000"
SHARE_OPT="-fsdev local,id=fsdev0,path=$SHARED_DIR,security_model=none -device virtio-9p-pci,fsdev=fsdev0,mount_tag=hostshare"
# ==============================================

DO_PACK=false
DO_DEBUG=false

for arg in "$@"; do
    if [ "$arg" == "pack" ]; then DO_PACK=true; fi
    if [ "$arg" == "debug" ]; then DO_DEBUG=true; fi
done

# [步骤 1] 按需重新打包 Rootfs
if [ "$DO_PACK" = true ]; then
    echo " [1/3] 正在重新打包 Rootfs..."
    cd $ROOTFS_DIR
    find . -print0 | cpio --null -ov --format=newc | gzip -9 > $ROOTFS_IMG
fi

# [步骤 2] 自动增量编译内核
echo " [2/3] 正在检查并增量编译内核..."
cd $KERNEL_DIR
make -j$(nproc) bzImage
if [ $? -ne 0 ]; then
    echo " 编译失败！请检查代码语法错误。"
    exit 1
fi

# [步骤 3] 启动 QEMU 虚拟机
cd $WORKSPACE
# 日志双写并设置 signal=off
LOGGING_OPT="-chardev stdio,id=char0,logfile=$LOG_FILE,mux=on,signal=off -serial chardev:char0 -mon chardev=char0"

if [ "$DO_DEBUG" = true ]; then
    echo " [3/3] 启动 QEMU (调试模式)... 等待 GDB 接入 (:1234)"
    qemu-system-x86_64 \
        -kernel $KERNEL_BZIMAGE -initrd $ROOTFS_IMG \
        -append "console=ttyS0 nokaslr loglevel=8" \
        -display none \
        -m $QEMU_MEM -smp $QEMU_CPU -cpu host \
        $NETWORK_OPT $SHARE_OPT $LOGGING_OPT \
        -s -S
else
    echo " [3/3] 启动 QEMU (全速模式)... 崩溃日志实时保存在 share/kernel_crash.log"
    echo " 提示：按 Ctrl+C 中断内部程序；按 Ctrl+A 然后按 X 强制退出虚拟机"
    qemu-system-x86_64 \
        -kernel $KERNEL_BZIMAGE -initrd $ROOTFS_IMG \
        -append "console=ttyS0 nokaslr quiet" \
        -display none \
        -m $QEMU_MEM -smp $QEMU_CPU -cpu host \
        $NETWORK_OPT $SHARE_OPT $LOGGING_OPT \
        -enable-kvm
fi