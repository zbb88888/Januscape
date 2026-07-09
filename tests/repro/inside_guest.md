# 来宾内复现步骤

## 目标

这份说明用于在 L1 来宾内部准备 Januscape PoC。执行最终触发步骤会导致 L0 宿主机 KVM panic，只应在可接受宕机的测试主机上进行。

## 准备 L1

在宿主机执行：

```bash
./tests/repro/download_guest_image.sh
sudo apt-get install -y cloud-image-utils
./tests/repro/create_seed_iso.sh
./tests/repro/start_l1_guest.sh
```

默认会把仓库通过 9p 挂载到 L1 的 `/mnt/januscape`，并把 SSH 转发到宿主机 `2222` 端口。

## 使用 libvirt 启动 L1（替代方案）

如果要改用 libvirt 测试，在宿主机执行：

```bash
sudo apt-get install -y libvirt-daemon-system libvirt-clients virtinst qemu-utils
./tests/repro/download_guest_image.sh
./tests/repro/create_seed_iso.sh
./tests/repro/start_l1_guest_libvirt.sh
```

脚本会输出 `ip`、`ssh_user`、`ssh_pass`。可直接登录：

```bash
ssh <ssh_user>@<ip>
```

结束测试并清理域：

```bash
./tests/repro/stop_l1_guest_libvirt.sh
```

需要同时删除 overlay：

```bash
REMOVE_OVERLAY=1 ./tests/repro/stop_l1_guest_libvirt.sh
```

### 超时与一键测试（避免卡住）

`repro` 脚本已支持超时环境变量：

- `DOWNLOAD_TIMEOUT_SEC`：镜像下载超时（默认 1800）
- `SEED_CREATE_TIMEOUT_SEC`：seed 生成超时（默认 120）
- `L1_RUNTIME_TIMEOUT_SEC`：直接 qemu 启动运行超时（默认 3600，`0` 表示不限制）
- `VIRT_INSTALL_TIMEOUT_SEC`：libvirt 安装域超时（默认 300）
- `DHCP_WAIT_TIMEOUT_SEC`：libvirt 等待 DHCP 超时（默认 240）

新增一键脚本：

```bash
./tests/repro/run_poc_libvirt.sh
```

这个脚本会自动：

1. 等待 SSH 就绪（有超时）
2. 上传 `poc.c` 和 `Makefile`
3. 等待 apt 锁释放（有超时）
4. 编译并加载 PoC（整体有超时）

可调参数：

- `SSH_READY_TIMEOUT_SEC`（默认 300）
- `GUEST_CMD_TIMEOUT_SEC`（默认 1800）
- `APT_LOCK_WAIT_TIMEOUT_SEC`（默认 180）
- `POST_TRIGGER_SLEEP_SEC`（默认 20）

## L1 内检查

登录 L1 后，先确认嵌套虚拟化对来宾可见：

```bash
grep -E -m1 'vmx|svm' /proc/cpuinfo
ls -l /dev/kvm
```

如果这里看不到 `vmx` 或 `svm`，说明 L1 没拿到嵌套虚拟化能力，PoC 不会触发目标路径。

## 编译与加载

在 L1 中：

```bash
cd /mnt/januscape
sudo apt-get install -y build-essential linux-headers-$(uname -r)
make clean && make
```

Intel 路径：

```bash
sudo rmmod kvm_intel
sudo insmod poc.ko
```

AMD 路径：

```bash
sudo rmmod kvm_amd
sudo insmod poc.ko amd=1
```

## 风险

- 公开 PoC 的成功结果是 L0 宿主机 KVM panic，不是温和失败。
- 在实际执行最终 `insmod` 前，建议提前开好宿主机串口、IPMI 或外部登录通道。
- 如果宿主机当前内核已经带修复，PoC 可能无法复现，也可能只表现为 guest 侧异常而不会触发 host panic。