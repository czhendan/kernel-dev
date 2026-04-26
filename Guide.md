
---

# Linux 内核开发环境搭建

**架构体系**：Windows 11 + WSL2 (Ubuntu 24.04) + VS Code + QEMU
**内核版本**：Linux 6.19.8 (Stable)
**环境配置**：2G 内存 / 4 核 CPU / 完整标准网络支持 / 9P 宿主共享文件夹 / 崩溃日志双写 / 完美任务控制与按键透传

---

## 第一部分：基础设施搭建与权限配置

### 1. 准备 WSL2 (Ubuntu 24.04)
1. **安装 WSL2**：打开 Windows 的 PowerShell（以管理员身份运行），执行：
   ```powershell
   wsl --install -d Ubuntu-24.04
   ```
2. **初始化系统**：重启电脑后，在开始菜单打开 `Ubuntu 24.04`，按提示设置 Linux 的用户名和密码。
3. **验证 KVM 硬件加速**：在 Ubuntu 终端内执行以下命令，确保底层虚拟化已开启：
   ```bash
   sudo apt update && sudo apt upgrade -y
   sudo apt install -y cpu-checker
   kvm-ok
   ```
   > **注意**：如果输出 `KVM acceleration can be used`，说明完美支持。如果报错，请进入 Windows 主板 BIOS 开启 “Intel VT-x” 或 “AMD-V” 虚拟化支持。

### 2. 安装编译工具链与配置 KVM 权限
在 Ubuntu 终端中执行：
```bash
sudo apt install -y build-essential gcc make qemu-system-x86 gdb flex bison libssl-dev libelf-dev bc cpio clangd python3 wget busybox-static dos2unix kmod iproute2
```

**配置 KVM 使用权限**（防止启动时提示 Permission denied）：
出于安全机制，普通用户默认无法调用 `/dev/kvm`。我们需要将当前用户加入 `kvm` 组：
1. 在 Ubuntu 终端执行：
   ```bash
   sudo usermod -aG kvm $USER
   ```
2. **强制刷新权限**：关闭当前的 Ubuntu 终端或 VS Code。打开 Windows 的 PowerShell，执行以下命令彻底重启 WSL 后台服务：
   ```powershell
   wsl --shutdown
   ```
3. 重新打开 Ubuntu 终端进行后续操作。

---

## 第二部分：内核编译与系统配置

> 以下所有操作必须在 Linux 的原生家目录（`~`）下进行

### 1. 获取 Linux 6.19.8 源码
```bash
mkdir -p ~/kernel-dev && cd ~/kernel-dev
wget https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.19.8.tar.xz
tar -xf linux-6.19.8.tar.xz
cd linux-6.19.8
```

### 2. 内核配置
开启虚拟化优化、网络、调试信息以及 9P 共享文件夹支持：
```bash
# 生成基础配置与 QEMU 精简配置
make x86_64_defconfig
make kvm_guest.config

# 开启 GDB 调试支持与网卡驱动
./scripts/config -e DEBUG_INFO_DWARF4
./scripts/config -e GDB_SCRIPTS
./scripts/config -d RANDOMIZE_BASE
./scripts/config -e VIRTIO_NET
./scripts/config -e E1000

# 开启 9P 共享文件夹支持
./scripts/config -e NET_9P
./scripts/config -e NET_9P_VIRTIO
./scripts/config -e 9P_FS
./scripts/config -e 9P_FS_POSIX_ACL

# 应用修改并进行编译
make olddefconfig
make -j$(nproc) bzImage
```

---

## 第三部分：构建纯净运行环境与自动化脚本

### 1.  Rootfs 构建 (集成标准 DHCP 网络引擎)
**创建脚本，在终端中一次性执行**：

```bash
cd ~/kernel-dev
# 1. 创建共享文件夹与基础目录
mkdir -p share
rm -rf rootfs
mkdir -p rootfs/{bin,sbin,etc,proc,sys,dev,usr/bin,usr/sbin,mnt/share}

# 2. 拷贝静态版 busybox 并使用【硬链接】安装指令
cp /bin/busybox rootfs/bin/
cd rootfs/bin
./busybox --install .
cd ~/kernel-dev/rootfs

# 3. 配置标准的主机名和本地解析
echo "kernel-dev" > etc/hostname
cat << 'EOF' > etc/hosts
127.0.0.1   localhost
::1         localhost
EOF

# 4. DHCP 动态网络配置回调脚本
cat << 'EOF' > etc/udhcpc.script
#!/bin/sh
case "$1" in
    deconfig)
        ip addr flush dev $interface
        ;;
    renew|bound)
        ip addr add $ip/$mask dev $interface
        if [ -n "$router" ]; then
            for i in $router; do
                ip route add default via $i dev $interface
            done
        fi
        echo -n > /etc/resolv.conf
        if [ -n "$dns" ]; then
            for i in $dns; do
                echo "nameserver $i" >> /etc/resolv.conf
            done
        fi
        ;;
esac
exit 0
EOF

# 5. 生成 init 脚本
cat << 'EOF' > init
#!/bin/sh
# 挂载核心文件系统与设备节点
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev

# 设置主机名
hostname -F /etc/hostname

# 启动网络网卡并调用 DHCP 回调脚本（自动获取 IP/路由/DNS）
ip link set lo up
ip link set eth0 up
udhcpc -i eth0 -s /etc/udhcpc.script -q

# 自动挂载宿主机的共享文件夹
mkdir -p /mnt/share
mount -t 9p -o trans=virtio,version=9p2000.L hostshare /mnt/share

echo -e "\n======================================================="
echo -e "  Linux 6.19.8 Dev Environment Boot Success!"
echo -e "  [网络就绪] 动态IP与DNS已配置，支持全网域名访问！"
echo -e "  [宿主挂载] 共享目录位于: /mnt/share"
echo -e "=======================================================\n"

# 绑定真实的 TTY 控制台，开启任务控制 (Job Control)
exec setsid cttyhack /bin/sh
EOF

# 6. 强制消除可能的换行符污染并赋予执行权限
dos2unix etc/udhcpc.script init
chmod +x etc/udhcpc.script init

# 7. 重新打包并压缩
find . -print0 | cpio --null -ov --format=newc | gzip -9 > ../rootfs.cpio.gz
```

### 2. 自动化启动与调试 (`dev_tool.sh`)
在 `~/kernel-dev` 目录下新建 `dev_tool.sh`：

```bash name=dev_tool.sh
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
    echo "[1/3] 正在重新打包 Rootfs..."
    cd $ROOTFS_DIR
    find . -print0 | cpio --null -ov --format=newc | gzip -9 > $ROOTFS_IMG
fi

# [步骤 2] 自动增量编译内核
echo "[2/3] 正在检查并增量编译内核..."
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
    echo "[3/3] 启动 QEMU (调试模式)... 等待 GDB 接入 (:1234)"
    qemu-system-x86_64 \
        -kernel $KERNEL_BZIMAGE -initrd $ROOTFS_IMG \
        -append "console=ttyS0 nokaslr loglevel=8" \
        -display none \
        -m $QEMU_MEM -smp $QEMU_CPU -cpu host \
        $NETWORK_OPT $SHARE_OPT $LOGGING_OPT \
        -s -S
else
    echo "[3/3] 启动 QEMU (全速模式)... 崩溃日志实时保存在 share/kernel_crash.log"
    echo "提示：按 Ctrl+C 中断内部程序；按 Ctrl+A 然后按 X 强制退出虚拟机"
    qemu-system-x86_64 \
        -kernel $KERNEL_BZIMAGE -initrd $ROOTFS_IMG \
        -append "console=ttyS0 nokaslr quiet" \
        -display none \
        -m $QEMU_MEM -smp $QEMU_CPU -cpu host \
        $NETWORK_OPT $SHARE_OPT $LOGGING_OPT \
        -enable-kvm
fi
```
赋予脚本执行权限：
```bash
chmod +x ~/kernel-dev/dev_tool.sh
```

---

## 第四部分：日常开发与实战工作流

### 1. 唤醒环境与 IDE 接入
1. 在 Windows 上打开 **VS Code**（需安装微软官方 `WSL` 扩展）。
2. 使用快捷键 `Ctrl + Shift + P`，输入 `WSL: Connect to WSL`，连接至 Ubuntu。
3. 打开工作区目录：`/home/你的用户名/kernel-dev`。
4. **代码跳转配置（首次运行或更换内核时需要）**：
   在 VS Code 集成终端（`Ctrl + ~`）中执行：
   ```bash
   cd linux-6.19.8
   ./scripts/clang-tools/gen_compile_commands.py
   ```
   并在 VS Code 安装 **Clangd** 扩展，禁用默认的 C/C++ IntelliSense，即可享受千万行代码毫秒级的源码跳转体验。

### 2. 快捷键指南
*   **终止虚拟机里的程序**：按下 `Ctrl + C`。
*   **关闭/退出整个虚拟机**：先按下 `Ctrl + A`，松开后，再按 `X`。

### 3. 工作流 A：修改内核与快速验证
当你在源码中（如 `net/ipv4/tcp.c`）修改了底层逻辑：
```bash
# 在 VS Code 终端中执行（带 pack 参数确保文件系统也是最新的）
./dev_tool.sh pack
```
脚本将完成增量编译并拉起 QEMU，同时保留之前的编译输出。进入虚拟机后，直接执行 `ping www.baidu.com` 等命令验证你的网络逻辑。

### 4. 工作流 B：用户态程序“热测试”
免去反复打包系统的烦恼，直接在共享文件夹中测试你的 C 程序：
1. **启动虚拟机**：直接运行 `./dev_tool.sh`
2. **编写代码**：在 VS Code 中，在 `share` 目录下新建 `test.c`。
3. **宿主机编译**：在 VS Code 的 WSL 终端新建一个窗口，执行（注意加 `-static` 防止缺动态库）：
   ```bash
   gcc -static share/test.c -o share/test_app
   ```
4. **虚拟机运行**：切回到 QEMU 的命令行终端中，直接运行：
   ```sh
   cd /mnt/share
   ./test_app
   ```

### 5. 工作流 C：内核崩溃查障 (Core Dump/Panic)
如果代码导致系统严重崩溃（Kernel Panic 卡死）：
1. 强制退出 QEMU (`Ctrl+A` -> `X`)。
2. 在 VS Code 中打开 `share/kernel_crash.log` 文件。
3. 该文件完整保留了崩溃那一刻的终端输出、调用栈（Call Trace）、寄存器状态和行号，配合源码直接定位 Bug。

### 6. 工作流 D：GDB 断点调试
1. **启动调试服务端**（终端 1）：
   ```bash
   ./dev_tool.sh debug
   ```
2. **挂载 GDB 客户端**（终端 2，在 VS Code 中拆分出一个新终端）：
   ```bash
   cd ~/kernel-dev/linux-6.19.8
   gdb vmlinux -ex "target remote :1234"
   ```
3. **下断点与执行**（GDB 内部）：
   ```text
   (gdb) break tcp_v4_rcv
   (gdb) continue
   ```