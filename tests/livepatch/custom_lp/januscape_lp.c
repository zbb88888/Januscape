#include <linux/errno.h>
#include <linux/kprobes.h>
#include <linux/mm.h>
#include <linux/livepatch.h>
#include <linux/module.h>
#include <linux/types.h>
#include <linux/kvm_host.h>
#include <linux/atomic.h>

#include <asm/kvm_host.h>

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Januscape test workbench");
MODULE_DESCRIPTION("Custom livepatch scaffold for kvm_mmu_get_child_sp");
MODULE_INFO(livepatch, "Y");

/*
 * Safety defaults:
 * - enable_patch=0: module loads in dry-run mode (no livepatch activation)
 * - allow_interim_semantics=0: refuse activation unless explicitly allowed
 */
static bool enable_patch;
module_param(enable_patch, bool, 0400);
MODULE_PARM_DESC(enable_patch, "Enable livepatch on load (default: false)");

static bool allow_interim_semantics;
module_param(allow_interim_semantics, bool, 0400);
MODULE_PARM_DESC(allow_interim_semantics,
	"Allow interim replacement semantics for test hosts only (default: false)");

struct shadow_page_caches {
	void *page_header_cache;
	void *shadow_page_cache;
	void *shadowed_info_cache;
};

/*
 * Current-host layout view derived from runtime BTF for 6.17.0-35-generic.
 * We only need role.word and gfn to reproduce the upstream reuse gate.
 */
struct januscape_shadow_page_view {
	u8 pad_to_role[36];
	union kvm_mmu_page_role role;
	gfn_t gfn;
};

#define JANUSCAPE_SPTE_MMU_PRESENT_MASK BIT_ULL(11)
#define JANUSCAPE_PT_PAGE_SIZE_MASK BIT_ULL(7)

#ifdef CONFIG_DYNAMIC_PHYSICAL_MASK
#define JANUSCAPE_SPTE_BASE_ADDR_MASK (physical_mask & ~(u64)(PAGE_SIZE - 1))
#else
#define JANUSCAPE_SPTE_BASE_ADDR_MASK (((1ULL << 52) - 1) & ~(u64)(PAGE_SIZE - 1))
#endif

static inline bool januscape_is_shadow_present_pte(u64 pte)
{
	return !!(pte & JANUSCAPE_SPTE_MMU_PRESENT_MASK);
}

static inline bool januscape_is_large_pte(u64 pte)
{
	return pte & JANUSCAPE_PT_PAGE_SIZE_MASK;
}

static inline struct januscape_shadow_page_view *januscape_spte_to_child_sp(u64 spte)
{
	struct page *page = pfn_to_page((spte & JANUSCAPE_SPTE_BASE_ADDR_MASK) >> PAGE_SHIFT);

	return (struct januscape_shadow_page_view *)page_private(page);
}

typedef unsigned long (*kallsyms_lookup_name_t)(const char *name);
typedef union kvm_mmu_page_role (*kvm_mmu_child_role_t)(u64 *sptep,
							 bool direct,
							 int access);
typedef struct kvm_mmu_page *(*kvm_mmu_get_shadow_page_t)(struct kvm *kvm,
							  struct kvm_vcpu *vcpu,
							  struct shadow_page_caches *caches,
							  gfn_t gfn,
							  union kvm_mmu_page_role role);

static kallsyms_lookup_name_t kallsyms_lookup_name_fn;
static kvm_mmu_child_role_t kvm_mmu_child_role_fn;
static kvm_mmu_get_shadow_page_t kvm_mmu_get_shadow_page_fn;
static void *kvm_mmu_get_child_sp_addr;

static atomic64_t lp_calls = ATOMIC64_INIT(0);
static atomic64_t lp_eexist = ATOMIC64_INIT(0);
static atomic64_t lp_fallback = ATOMIC64_INIT(0);

static void januscape_log_counters(const char *tag)
{
	pr_info("counter[%s]: calls=%lld eexist=%lld fallback=%lld\n",
		tag,
		(long long)atomic64_read(&lp_calls),
		(long long)atomic64_read(&lp_eexist),
		(long long)atomic64_read(&lp_fallback));
}

static int resolve_kallsyms_lookup_name(void)
{
	struct kprobe kp = {
		.symbol_name = "kallsyms_lookup_name",
	};
	int ret;

	ret = register_kprobe(&kp);
	if (ret)
		return ret;

	kallsyms_lookup_name_fn = (kallsyms_lookup_name_t)kp.addr;
	unregister_kprobe(&kp);

	if (!kallsyms_lookup_name_fn)
		return -ENOENT;

	return 0;
}

static int resolve_kvm_symbols(void)
{
	int ret;

	ret = resolve_kallsyms_lookup_name();
	if (ret)
		return ret;

	kvm_mmu_child_role_fn = (kvm_mmu_child_role_t)
		kallsyms_lookup_name_fn("kvm_mmu_child_role");
	kvm_mmu_get_shadow_page_fn = (kvm_mmu_get_shadow_page_t)
		kallsyms_lookup_name_fn("__kvm_mmu_get_shadow_page");
	kvm_mmu_get_child_sp_addr = (void *)kallsyms_lookup_name_fn("kvm_mmu_get_child_sp");

	if (!kvm_mmu_child_role_fn || !kvm_mmu_get_shadow_page_fn || !kvm_mmu_get_child_sp_addr)
		return -ENOENT;

	pr_info("resolved symbols: target=%ps kvm_mmu_child_role=%ps __kvm_mmu_get_shadow_page=%ps\n",
		kvm_mmu_get_child_sp_addr, kvm_mmu_child_role_fn, kvm_mmu_get_shadow_page_fn);

	return 0;
}

/*
 * Interim replacement path.
 *
 * This implementation intentionally avoids the buggy early-return pattern and
 * delegates page lookup/allocation to __kvm_mmu_get_shadow_page(). It is only
 * for controlled test hosts while final role/gfn equivalence gating is added.
 */
static struct kvm_mmu_page *lp_kvm_mmu_get_child_sp(struct kvm_vcpu *vcpu,
						     u64 *sptep,
						     gfn_t gfn,
						     bool direct,
						     int access)
{
	union kvm_mmu_page_role role;
	struct shadow_page_caches caches;
	struct januscape_shadow_page_view *child;
	u64 spte;

	if (WARN_ON_ONCE(!kvm_mmu_child_role_fn || !kvm_mmu_get_shadow_page_fn))
		return ERR_PTR(-EINVAL);

	atomic64_inc(&lp_calls);

	role = kvm_mmu_child_role_fn(sptep, direct, access);
	spte = READ_ONCE(*sptep);

	if (januscape_is_shadow_present_pte(spte) && !januscape_is_large_pte(spte)) {
		child = januscape_spte_to_child_sp(spte);
		if (child && child->gfn == gfn && child->role.word == role.word) {
			atomic64_inc(&lp_eexist);
			return ERR_PTR(-EEXIST);
		}
	}

	caches.page_header_cache = &vcpu->arch.mmu_page_header_cache;
	caches.shadow_page_cache = &vcpu->arch.mmu_shadow_page_cache;
	caches.shadowed_info_cache = &vcpu->arch.mmu_shadowed_info_cache;
	atomic64_inc(&lp_fallback);

	return kvm_mmu_get_shadow_page_fn(vcpu->kvm, vcpu, &caches, gfn, role);
}

static struct klp_func januscape_funcs[] = {
	{
		.old_name = "kvm_mmu_get_child_sp",
		.new_func = lp_kvm_mmu_get_child_sp,
	},
	{ }
};

static struct klp_object januscape_objs[] = {
	{
		.name = "kvm",
		.funcs = januscape_funcs,
	},
	{ }
};

static struct klp_patch januscape_patch = {
	.mod = THIS_MODULE,
	.objs = januscape_objs,
};

static int __init januscape_lp_init(void)
{
	int ret;

	ret = resolve_kvm_symbols();
	if (ret) {
		pr_err("failed to resolve KVM symbols: %d\n", ret);
		return ret;
	}

	if (!enable_patch) {
		pr_info("loaded in dry-run mode; livepatch not enabled\n");
		return 0;
	}

	if (!allow_interim_semantics) {
		pr_err("refusing to enable patch without allow_interim_semantics=1\n");
		return -EPERM;
	}

	pr_warn("enabling INTERIM semantics on test host only; do not use in production\n");

	ret = klp_enable_patch(&januscape_patch);
	if (ret) {
		pr_err("klp_enable_patch failed: %d\n", ret);
		return ret;
	}

	pr_info("livepatch enabled (interim semantics)\n");
	januscape_log_counters("post-enable");
	return 0;
}

static void __exit januscape_lp_exit(void)
{
	januscape_log_counters("module-exit");
	pr_info("module exit\n");
}

module_init(januscape_lp_init);
module_exit(januscape_lp_exit);
