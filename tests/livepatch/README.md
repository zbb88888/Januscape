# livepatch 取证与设计说明

## 当前主机结论

- 当前宿主机启用了 `CONFIG_LIVEPATCH=y`、`CONFIG_DYNAMIC_FTRACE=y`、`CONFIG_DEBUG_INFO_BTF=y`。
- `kallsyms_lookup_name` 在 `/proc/kallsyms` 中可见。
- `kvm` 模块自己的 BTF 位于 `/sys/kernel/btf/kvm`。
- `kvm_mmu_get_child_sp`、`kvm_mmu_child_role`、`__kvm_mmu_get_shadow_page` 都能在 `kallsyms` 中看到，目标模块名是 `kvm`。

## 重要发现

对当前运行中的 Ubuntu `6.17.0-35-generic` 模块反汇编后，`kvm_mmu_get_child_sp` 的快路径形状与公开 write-up 里的易受攻击源码片段并不一致。也就是说：

- 不能直接假设当前宿主机上的函数正文和上游提交 `81ccda30b4e8` 的前后对比完全相同。
- 在没有拿到这版 Ubuntu HWE 6.17 对应源码树之前，直接编写“替换整个函数正文”的 livepatch 风险很高。

这不代表宿主机一定安全，只代表 livepatch 必须以本机真实模块代码为准，而不能只按上游文档抄补丁。

## 已落地的内容

- `inspect_kvm_target.sh`：采集 livepatch 所需的宿主机真实证据，包括：
  - 内核配置
  - 目标符号的 `kallsyms`
  - `kvm` 模块 BTF
  - `kvm.ko` 的反汇编
  - `kvm_mmu_get_child_sp`、`kvm_mmu_child_role`、`__kvm_mmu_get_shadow_page` 的局部切片
- `fetch_matching_kernel_source.sh`：基于当前运行内核包的 `Built-Using` 元数据，自动下载并解出匹配的 Ubuntu `linux-hwe-6.17` 源码。
- `check_fix_status.sh`：直接在解出的匹配源码里检查 `kvm_mmu_get_child_sp()` 当前形态，判断更接近“已修复”还是“疑似脆弱”。
- `upstream_fix.diff`：公开上游修复的核心逻辑差异，便于对照。

## 建议的 livepatch 路线

1. 先运行 `./tests/livepatch/inspect_kvm_target.sh` 固化本机证据。
2. 运行 `./tests/livepatch/fetch_matching_kernel_source.sh` 获取与 `6.17.0-35.35~24.04.1` 完全对应的 Ubuntu `linux-hwe-6.17` 源码。
3. 运行 `./tests/livepatch/check_fix_status.sh`，先判断当前宿主源码是否已经带修复。
4. 以该源码为准生成最小函数替换 patch，而不是直接照搬上游提交。
5. 在测试窗口先做对照实验：
   - 未打 patch 的宿主机
   - 打了 patch 的宿主机
6. 用同一份 L1 来宾步骤跑 PoC，观察 host 是否仍然 panic。

## 当前匹配源码与 Ubuntu 安全状态的结论

对当前宿主机匹配的 Ubuntu HWE `6.17.0-35.35~24.04.1` 源码检查后，`kvm_mmu_get_child_sp()` 的形态与上游 `81ccda30b4e8` 修复前后都不完全一致，片段如下：

```c
if (is_shadow_present_pte(*sptep) && !is_large_pte(*sptep))
	return ERR_PTR(-EEXIST);
```

这个形态不能直接等价为“已修复”。应以 Ubuntu 官方安全跟踪与 Pro 状态为准。当前机器上执行：

```bash
pro fix CVE-2026-53359
```

返回结果为 `Sorry, no fix is available yet.`，并显示 `linux` 与 `linux-hwe-6.17` 仍受影响。

因此当前更稳妥的结论是：

- 上游主线修复已存在，但 Ubuntu 对应内核分支在当前时点仍显示“未提供修复”
- Ubuntu 官方 Livepatch 是否已覆盖该 CVE 不能凭源码片段推断，应以 `canonical-livepatch`/`pro` 状态和 LSN 为准

## 应急缓解

如果目标只是先阻断公开 PoC 的可利用前提，而不是保留嵌套虚拟化功能，最务实的缓解仍然是关闭 nested virtualization。这不是 livepatch，但它比未经源码校准的函数热补丁更稳。