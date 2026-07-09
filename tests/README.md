# tests

这个目录统一存放 Januscape 的本地检查脚本与分析文档。

建议先阅读 `tests/workflow.md`，它把依赖准备、构建、测试、复现与 livepatch 取证串成了一条完整操作流程。

## 文档入口

- `tests/workflow.md`：完整操作手册
- `tests/project_analysis.md`：项目分析与当前主机结论
- `tests/repro/inside_guest.md`：L1 来宾内复现步骤
- `tests/livepatch/README.md`：livepatch 取证与设计说明

## 常用脚本

先检查当前宿主机环境：

```bash
./tests/check_kvm_env.sh
```

如果缺少 QEMU/KVM 工具，在 root 下安装：

```bash
./tests/install_qemu_kvm.sh
```

L1 来宾实验环境脚本位于 `tests/repro/`。

livepatch 前置取证和设计说明位于 `tests/livepatch/`。

每次运行 `check_kvm_env.sh` 都会把完整报告写到 `tests/artifacts/`。