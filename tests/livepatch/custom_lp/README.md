# Januscape Custom Livepatch Workbench

This directory is the starting point for a non-Pro custom livepatch implementation.

## Scope

- Target: `kvm_mmu_get_child_sp` in module `kvm`
- Upstream reference commit: `81ccda30b4e8`
- Goal: build a minimal replacement function path with controlled rollout and rollback

## Current status

- Phase 0 completed: feasibility assessment and target metadata collection path are defined.
- Phase 1 started: first compilable livepatch module scaffold is implemented.

Implemented files:
- `januscape_lp.c`
- `load_dry_run.sh`
- `attempt_enable_interim.sh`
- `unload.sh`
- `disable_and_unload.sh`
- `validate_cycle.sh`
- `build_for_node.sh`
- `preflight_node.sh`

What this first implementation does:
- Resolves static KVM helper addresses at runtime via kprobe -> `kallsyms_lookup_name`.
- Provides a replacement function and livepatch metadata wiring for `kvm_mmu_get_child_sp`.
- Uses safety-first defaults: load is dry-run unless explicitly enabled by module params.

What is now implemented more precisely:
- Before returning `ERR_PTR(-EEXIST)`, the replacement now checks the same high-level gate as upstream intent:
	- SPTE is MMU-present
	- SPTE is not a large-page mapping
	- child shadow page exists
	- child `gfn` matches requested `gfn`
	- child `role.word` matches newly computed `role.word`

What is still pending for final semantic parity with `81ccda30b4e8`:
- Close behavior diff review and run full regression matrix.

Current practical blocker:
- Installed Ubuntu kernel headers on this host do not expose several internal SPTE helpers (`is_shadow_present_pte`, `is_large_pte`, `spte_to_child_sp`).
- Exact upstream condition-text parity therefore cannot be implemented by simple include-level reuse in this workspace.
- The current module reconstructs those helpers locally using upstream definitions plus runtime/BTF-validated layout assumptions for this exact kernel build.

## Quick start

1. Collect runtime inputs:

```bash
./tests/livepatch/custom_lp/collect_inputs.sh
```

2. Review generated artifacts under:

```bash
tests/livepatch/custom_lp/artifacts/
```

3. Implement replacement function source in this directory.

4. Build out-of-tree module (template Makefile provided):

```bash
make -C /lib/modules/$(uname -r)/build M=$(pwd)/tests/livepatch/custom_lp modules
```

5. Load in dry-run mode (safe default):

```bash
./tests/livepatch/custom_lp/load_dry_run.sh
```

6. Unload module:

```bash
./tests/livepatch/custom_lp/unload.sh
```

If the patch was enabled and module appears in-use, use:

```bash
./tests/livepatch/custom_lp/disable_and_unload.sh
```

7. Test-only interim enable path (explicit opt-in):

```bash
./tests/livepatch/custom_lp/attempt_enable_interim.sh
```

8. Run the full validation cycle and archive artifacts:

```bash
./tests/livepatch/custom_lp/validate_cycle.sh
```

9. Build a node-specific ko bundle (Ubuntu 22/24 targeted):

```bash
./tests/livepatch/custom_lp/build_for_node.sh
```

0. (Recommended first step) Run node preflight gate:

```bash
./tests/livepatch/custom_lp/preflight_node.sh
```

Interpretation:
- `ready_build=1`: node is ready to build node-specific ko.
- `ready_validate=1`: node is ready for full validate cycle (`--with-validate`).

Optional (run full validation after build):

```bash
./tests/livepatch/custom_lp/build_for_node.sh --with-validate
```

Output bundle includes:
- kernel-specific ko (`januscape_lp-$(uname -r).ko`)
- checksum
- modinfo/vermagic
- build logs
- summary metadata

Suggested per-node sequence:
1. `./tests/livepatch/custom_lp/preflight_node.sh`
2. `./tests/livepatch/custom_lp/build_for_node.sh`
3. `./tests/livepatch/custom_lp/build_for_node.sh --with-validate` (only on test nodes)

## Safety notes

- Do not load an unvalidated patch module on production hosts.
- Keep out-of-band access and rollback path ready before any load test.
- `attempt_enable_interim.sh` is only for isolated test hosts.
- `disable_and_unload.sh` should be the default rollback command after enable tests.
- Livepatch rollback must wait for `transition` to clear before disabling `enabled`; this is handled by `disable_and_unload.sh`.
- `build_for_node.sh` is the recommended entrypoint for per-node Ubuntu 22/24 ko generation.
