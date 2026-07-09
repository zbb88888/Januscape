# Januscape 操作流程手册

这份文档记录当前项目的关键操作流程，包括宿主机依赖准备、环境检查、L1 来宾构建、PoC 测试、livepatch 取证以及后续修复验证路径。

## 1. 流程总览

建议按下面顺序执行：

1. 宿主机依赖准备
2. 宿主机 KVM 与嵌套虚拟化检查
3. L1 来宾镜像准备与启动
4. L1 内编译 `poc.ko`
5. 执行未修复基线测试
6. 宿主机 livepatch 取证
7. 获取匹配的 Ubuntu HWE 6.17 源码
8. 检查匹配源码里的修复状态
9. 构建 livepatch 模块
10. 在同一测试路径下做 patched / unpatched 对照验证

## 2. 宿主机依赖准备

当前仓库已经提供了自动化安装脚本：

```bash
sudo ./tests/install_qemu_kvm.sh
```

脚本当前覆盖：

- `qemu-system-x86`
- `qemu-utils`
- `qemu-kvm`
- `cpu-checker`
- `ovmf`

L1 cloud image 的 cloud-init 种子还需要：

```bash
sudo apt-get install -y cloud-image-utils
```

如果后续要构建 livepatch 模块，还应准备常见构建依赖：

```bash
sudo apt-get install -y build-essential binutils elfutils libelf-dev zstd dwarves
```

## 3. 宿主机环境检查

运行：

```bash
./tests/check_kvm_env.sh
```

这一步的目标是确认：

- CPU 是否暴露 `vmx` 或 `svm`
- `kvm` / `kvm_intel` / `kvm_amd` 是否已加载
- nested virtualization 是否已开启
- `/dev/kvm` 是否存在
- `qemu-system-x86_64`、`qemu-img`、`qemu-nbd` 是否可用

每次检查的完整报告会写到 `tests/artifacts/`。

## 4. L1 来宾准备

### 4.1 下载来宾镜像

```bash
./tests/repro/download_guest_image.sh
```

默认使用 Ubuntu 24.04 noble cloud image。也可以用环境变量覆盖：

```bash
IMAGE_URL=... ./tests/repro/download_guest_image.sh
```

### 4.2 生成 cloud-init seed

```bash
./tests/repro/create_seed_iso.sh
```

默认行为：

- 主机名：`januscape-l1`
- 用户名：`januscape`
- 仓库通过 9p 挂载到来宾 `/mnt/januscape`

可以通过环境变量覆盖：

```bash
VM_HOSTNAME=... VM_USERNAME=... ./tests/repro/create_seed_iso.sh
```

### 4.3 启动 L1

```bash
./tests/repro/start_l1_guest.sh
```

默认行为：

- 使用 `qemu-system-x86_64 -enable-kvm`
- `-cpu host`
- 4 vCPU
- 4096 MB 内存
- SSH 端口转发到宿主 `2222`
- 当前仓库通过 9p 共享到 L1

常见覆盖方式：

```bash
L1_MEMORY_MB=8192 L1_VCPUS=8 L1_SSH_PORT=2222 ./tests/repro/start_l1_guest.sh
```

## 5. L1 内检查与构建

登录 L1 后先检查嵌套虚拟化是否向来宾暴露：

```bash
grep -E -m1 'vmx|svm' /proc/cpuinfo
ls -l /dev/kvm
```

如果这里看不到 `vmx` 或 `svm`，说明 L1 不能再运行 L2，Januscape 的触发路径不会成立。

然后在 L1 内安装构建依赖并编译：

```bash
cd /mnt/januscape
sudo apt-get install -y build-essential linux-headers-$(uname -r)
make clean
make
```

编译成功的判据：

- 生成 `poc.ko`
- `make` 退出码为 0

## 6. 未修复基线测试

这是正式复现前的基线步骤。应在确认宿主机可接受 panic 的前提下执行。

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

预期现象取决于宿主机是否仍然易受影响：

- 易受影响：宿主机 KVM panic
- 已修复：PoC 可能不再触发 panic，或表现为 guest 内异常

在做这一步之前，建议提前准备：

- 宿主机串口或远程管理通道
- 外部登录会话
- 必要的 crash dump 或日志采集策略

## 7. 宿主机 livepatch 取证

在尝试任何 livepatch 之前，先固定本机真实 KVM 模块信息：

```bash
./tests/livepatch/inspect_kvm_target.sh
```

这一步会收集：

- 内核 livepatch/ftrace/BTF 配置
- 目标函数 `kallsyms`
- `kvm` 模块 BTF
- `kvm.ko` 反汇编
- `kvm_mmu_get_child_sp` 等关键函数局部切片

结果位于：

```bash
tests/livepatch/artifacts/
```

## 8. 当前 livepatch 设计边界

仓库里已经记录了上游修复核心逻辑：

```bash
tests/livepatch/upstream_fix.diff
```

但当前宿主机运行的是 Ubuntu HWE `6.17.0-35-generic`，其 `kvm.ko` 是发行版构建产物。当前已经确认：

- `kvm_mmu_get_child_sp` 在本机 `kvm` 模块中可见
- 宿主机具备 `CONFIG_LIVEPATCH=y`
- 仅靠已安装 headers 还不够可靠地生成该内部函数的热补丁
- 当前机器码快路径与公开 write-up 展示的源码片段并不完全一致

因此，livepatch 的下一步不应该直接“照抄上游补丁写模块”，而应该先拿到与本机完全匹配的 Ubuntu `linux-hwe-6.17` 源码。

获取脚本已经落地：

```bash
./tests/livepatch/fetch_matching_kernel_source.sh
```

默认会：

- 读取 `linux-image-$(uname -r)` 的 `Built-Using`
- 定位匹配的 `linux-hwe-6.17` source stanza
- 下载 `.orig.tar.gz`、`.diff.gz`、`.dsc`
- 用 `dpkg-source -x` 解出源码

输出位置：

```bash
tests/livepatch/sources/
```

修复状态检查脚本：

```bash
./tests/livepatch/check_fix_status.sh
```

## 9. 后续 livepatch 构建路径

建议的后续顺序：

1. 运行 `./tests/livepatch/fetch_matching_kernel_source.sh`
2. 运行 `./tests/livepatch/check_fix_status.sh`
3. 对照 `inspect_kvm_target.sh` 的本机反汇编与 BTF
4. 定义最小替换函数，而不是盲目替换更大 KVM 路径
5. 构建 livepatch 模块
6. 在相同 L1 PoC 路径下做 patched / unpatched 对照测试

## 9.1 当前主机的新增判断

基于已下载的匹配 Ubuntu HWE `6.17.0-35.35~24.04.1` 源码，当前 `kvm_mmu_get_child_sp()` 形态如下：

```c
if (is_shadow_present_pte(*sptep) && !is_large_pte(*sptep))
	return ERR_PTR(-EEXIST);
```

这个形态与上游修复提交并不一致，不能单独作为“已修复”证据。以 Ubuntu 官方状态为准：

```bash
pro fix CVE-2026-53359
```

当前返回 `no fix is available yet`，并显示 `linux` 与 `linux-hwe-6.17` 仍受影响。因此：

- 当前宿主机不能视为“官方已修复基线”
- 如果要按 Ubuntu 标准流程评估 livepatch，需等待官方修复/LSN，或自行按标准 livepatch 流程做临时补丁验证

## 10. 构建与测试检查点

建议每个阶段都记录以下结果：

- 宿主环境检查报告路径
- L1 镜像版本与启动参数
- L1 内核版本
- `make` 构建输出
- 是否生成 `poc.ko`
- 宿主机是否 panic
- livepatch 取证产物目录
- patched / unpatched 的对照结果

## 12. 统一 A/B 验证入口

如果想把 unpatched / patched 对照、日志采集和汇总统一成一个入口，使用：

```bash
./tests/repro/run_ab_livepatch_validation.sh
```

默认行为：

- 场景：`unpatched patched`
- 每个场景轮数：`3`
- 每轮会自动：
	- 切换补丁状态（卸载或启用）
	- 重建并启动 L1
	- 触发 PoC
	- 采集 crash logs
	- 统计本轮起点以来的关键内核信号

输出目录：

```bash
tests/artifacts/ab-livepatch-<UTC_TIMESTAMP>/
```

核心输出：

- `summary.csv`：机器可读汇总
- `summary.md`：人工可读摘要
- `runs/<scenario>-roundN/`：每轮触发日志、VM 状态、内核筛选日志

常用参数：

```bash
AB_ROUNDS=5 \
AB_SCENARIOS="unpatched patched" \
AB_TRIGGER_TIMEOUT_SEC=3600 \
POC_INSMOD_ARGS="nvcpu=8 nflood=0 dwell=256 run_ms=0" \
./tests/repro/run_ab_livepatch_validation.sh
```

## 11. 相关文档

- `tests/project_analysis.md`
- `tests/repro/inside_guest.md`
- `tests/livepatch/README.md`