# Januscape 项目理解

## 仓库内容

- `poc.c` 是来宾机内加载的内核模块。它直接在 L1 来宾里构造并运行 L2，通过嵌套虚拟化触发 L0 宿主机 KVM/x86 shadow MMU 的缺陷。
- `README.md` 给出了最短使用路径：在来宾机里编译模块、卸载 `kvm_intel` 或 `kvm_amd`、再加载 `poc.ko`。
- `assets/write-up.md` 解释了根因：`kvm_mmu_get_child_sp()` 只按 `gfn` 复用 shadow page，没有校验 `role`，导致角色错配、rmap 损坏，最终在 `pte_list_remove()` 走到 `BUG_ON`。

## 复现前提

- 宿主机必须是 x86，并且 CPU 暴露 Intel `vmx` 或 AMD `svm`。
- 宿主机必须启用 KVM。
- 宿主机必须开启嵌套虚拟化，否则 L1 无法在来宾里再跑 L2。
- PoC 的触发点在宿主机内核 KVM，不在 QEMU 用户态本身；QEMU 只是常见的运行载体。
- 该 PoC 的公开版本目标是让宿主机 panic，不能在生产环境或共享宿主机上执行。

## 当前机器的最小结论

基于本次检查结果，当前环境已经满足宿主机侧的核心前提：

- `vmx` 标志存在，说明 CPU 支持 Intel VT-x。
- `kvm_intel` 与 `kvm` 模块已加载。
- `/sys/module/kvm_intel/parameters/nested=Y`，说明 Intel 嵌套虚拟化已开启。
- `/dev/kvm` 存在，说明用户态可以访问 KVM 设备。

缺口在用户态工具链。如果没有 `qemu-system-x86_64`、`qemu-img`、`kvm-ok` 等工具，不能方便地准备和验证复现环境。

## 关于当前宿主机是否仍然可复现

这是当前阶段最重要的不确定项。虽然公开 write-up 给出了上游根因和修复提交 `81ccda30b4e8`，但这台主机运行的是 Ubuntu HWE `6.17.0-35-generic`，其 `kvm` 模块是发行版构建产物，不应直接等同于上游主线同名函数。

已经确认的事实：

- `kvm_mmu_get_child_sp`、`kvm_mmu_child_role`、`__kvm_mmu_get_shadow_page` 在当前加载的 `kvm` 模块里可见。
- `CONFIG_LIVEPATCH=y`、`CONFIG_DYNAMIC_FTRACE=y`、`CONFIG_DEBUG_INFO_BTF=y`，因此这台主机具备定制 livepatch 的基础能力。
- 当前安装的 headers 不包含完整 `arch/x86/kvm/mmu/` 源码，因此不能只靠 `linux-headers` 直接生成可靠的 KVM 内部函数 livepatch。
- 对当前 `kvm.ko` 的反汇编显示，`kvm_mmu_get_child_sp` 的机器码形状和 write-up 中展示的脆弱源码片段并不完全一致，所以 livepatch 必须以本机真实模块代码和匹配源码为准。

## 本目录提供的内容

- `check_kvm_env.sh`：收集当前宿主机的 KVM、嵌套虚拟化与 QEMU 工具状态，并把报告写到 `tests/artifacts/`。
- `install_qemu_kvm.sh`：在基于 `apt` 的系统中安装 QEMU/KVM 相关包并做最小验证。
- `repro/`：L1 来宾复现实验脚本与来宾内操作说明。
- `livepatch/`：livepatch 所需的目标取证脚本、上游修复差异和设计说明。

## 安全边界

这里不提供会直接触发宿主机 panic 的自动化脚本，也不把 PoC 装配成一键攻击流程。当前落地内容只覆盖环境准备、前提校验和项目理解。