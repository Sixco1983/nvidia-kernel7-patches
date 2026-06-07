#!/bin/bash
# Reapplies 5 patches to NVIDIA DKMS source for kernel 7.x compatibility.
# Safe to run multiple times (idempotent — skips already-applied patches).
# Must be run as root. Called automatically by the apt hook after nvidia-current upgrades.

set -euo pipefail

# Auto-detect the installed NVIDIA version from the DKMS source directory.
NVIDIA_VER=$(ls -1d /usr/src/nvidia-current-* 2>/dev/null | sed 's|.*/nvidia-current-||' | sort -V | tail -1)
[[ -n "$NVIDIA_VER" ]] || { echo "ERROR: no nvidia-current source found in /usr/src/" >&2; exit 1; }
SRC="/usr/src/nvidia-current-${NVIDIA_VER}"
APPLIED=0
SKIPPED=0

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[*] $*"; }
skip() { echo "[-] SKIP (already applied): $*"; ((SKIPPED++)) || true; }
ok()   { echo "[+] Applied: $*"; ((APPLIED++)) || true; }

[[ $EUID -eq 0 ]] || die "Run as root (sudo $0)"
[[ -d "$SRC" ]]   || die "Source directory not found: $SRC"

backup() {
    local f="$1"
    [[ -f "${f}.orig" ]] || cp "$f" "${f}.orig"
}

# ─────────────────────────────────────────────────────────────────
# Patch 1: common/inc/nv-mm.h — VMA_LOCK_OFFSET compat define
# ─────────────────────────────────────────────────────────────────
F="${SRC}/common/inc/nv-mm.h"
MARKER='!defined(VMA_LOCK_OFFSET) && defined(VM_REFCNT_EXCLUDE_READERS_FLAG)'
if grep -qF "$MARKER" "$F"; then
    skip "nv-mm.h (VMA_LOCK_OFFSET compat)"
else
    backup "$F"
    python3 - "$F" <<'PYEOF'
import sys, re
path = sys.argv[1]
text = open(path).read()
needle = '#if NV_IS_EXPORT_SYMBOL_GPL___vma_start_write'
insert = (
    '/*\n'
    ' * Kernel 7.x renamed VMA_LOCK_OFFSET to VM_REFCNT_EXCLUDE_READERS_FLAG.\n'
    ' * Provide a compat define so nv-mmap.c compiles on both 6.x and 7.x.\n'
    ' */\n'
    '#if !defined(VMA_LOCK_OFFSET) && defined(VM_REFCNT_EXCLUDE_READERS_FLAG)\n'
    '#define VMA_LOCK_OFFSET VM_REFCNT_EXCLUDE_READERS_FLAG\n'
    '#endif\n'
    '\n'
)
assert needle in text, f"Anchor not found: {needle}"
text = text.replace(needle, insert + needle, 1)
open(path, 'w').write(text)
PYEOF
    ok "nv-mm.h (VMA_LOCK_OFFSET compat)"
fi

# ─────────────────────────────────────────────────────────────────
# Patch 2: nvidia/nv-mmap.c — __is_vma_write_locked() 1-arg API
# ─────────────────────────────────────────────────────────────────
F="${SRC}/nvidia/nv-mmap.c"
MARKER='VM_REFCNT_EXCLUDE_READERS_FLAG'
if grep -qF "$MARKER" "$F"; then
    skip "nv-mmap.c (__is_vma_write_locked 1-arg)"
else
    backup "$F"
    python3 - "$F" <<'PYEOF'
import sys
path = sys.argv[1]
text = open(path).read()
old = (
    '    NvU32 mm_lock_seq;\n'
    '    NvBool locked;\n'
    '    if (__is_vma_write_locked(vma, &mm_lock_seq))\n'
    '        return;\n'
)
new = (
    '    NvU32 mm_lock_seq;\n'
    '    NvBool locked;\n'
    '#if defined(VM_REFCNT_EXCLUDE_READERS_FLAG)\n'
    '    /* Kernel 7.x: __is_vma_write_locked() takes only vma; get seq separately */\n'
    '    if (__is_vma_write_locked(vma))\n'
    '        return;\n'
    '    mm_lock_seq = vma->vm_mm->mm_lock_seq.sequence;\n'
    '#else\n'
    '    if (__is_vma_write_locked(vma, &mm_lock_seq))\n'
    '        return;\n'
    '#endif\n'
)
assert old in text, "Anchor not found in nv-mmap.c"
text = text.replace(old, new, 1)
open(path, 'w').write(text)
PYEOF
    ok "nv-mmap.c (__is_vma_write_locked 1-arg)"
fi

# ─────────────────────────────────────────────────────────────────
# Patch 3: nvidia-drm/nvidia-dma-fence-helper.h — void return type
# ─────────────────────────────────────────────────────────────────
F="${SRC}/nvidia-drm/nvidia-dma-fence-helper.h"
MARKER='changed from int to void in kernel 7.x'
if grep -qF "$MARKER" "$F"; then
    skip "nvidia-dma-fence-helper.h (dma_fence_signal void)"
else
    backup "$F"
    python3 - "$F" <<'PYEOF'
import sys
path = sys.argv[1]
text = open(path).read()

old_sig = (
    '#else\n'
    '    return dma_fence_signal(fence);\n'
    '#endif\n'
    '}\n'
    '\n'
    'static inline int nv_dma_fence_signal_locked'
)
new_sig = (
    '#else\n'
    '    /* dma_fence_signal() changed from int to void in kernel 7.x.\n'
    '     * Callers never check the return value, so ignore it. */\n'
    '    dma_fence_signal(fence);\n'
    '    return 0;\n'
    '#endif\n'
    '}\n'
    '\n'
    'static inline int nv_dma_fence_signal_locked'
)
assert old_sig in text, "Anchor (signal) not found in nvidia-dma-fence-helper.h"
text = text.replace(old_sig, new_sig, 1)

old_locked = (
    '#else\n'
    '    return dma_fence_signal_locked(fence);\n'
    '#endif\n'
    '}\n'
    '\n'
    'static inline u64 nv_dma_fence_context_alloc'
)
new_locked = (
    '#else\n'
    '    /* dma_fence_signal_locked() changed from int to void in kernel 7.x.\n'
    '     * Callers never check the return value, so ignore it. */\n'
    '    dma_fence_signal_locked(fence);\n'
    '    return 0;\n'
    '#endif\n'
    '}\n'
    '\n'
    'static inline u64 nv_dma_fence_context_alloc'
)
assert old_locked in text, "Anchor (signal_locked) not found in nvidia-dma-fence-helper.h"
text = text.replace(old_locked, new_locked, 1)

open(path, 'w').write(text)
PYEOF
    ok "nvidia-dma-fence-helper.h (dma_fence_signal void)"
fi

# ─────────────────────────────────────────────────────────────────
# Patch 4: Makefile — gen-btf.sh alongside pahole-flags.sh
# ─────────────────────────────────────────────────────────────────
F="${SRC}/Makefile"
MARKER='gen-btf.sh'
if grep -qF "$MARKER" "$F"; then
    skip "Makefile (gen-btf.sh / PAHOLE_VARIABLES)"
else
    backup "$F"
    python3 - "$F" <<'PYEOF'
import sys
path = sys.argv[1]
text = open(path).read()
old = "  PAHOLE_VARIABLES=$(if $(wildcard $(KERNEL_SOURCES)/scripts/pahole-flags.sh),,\"PAHOLE=$(AWK) '$(PAHOLE_AWK_PROGRAM)'\")"
new = "  PAHOLE_VARIABLES=$(if $(or $(wildcard $(KERNEL_SOURCES)/scripts/pahole-flags.sh),$(wildcard $(KERNEL_SOURCES)/scripts/gen-btf.sh)),,\"PAHOLE=$(AWK) '$(PAHOLE_AWK_PROGRAM)'\")"
assert old in text, f"Anchor not found in Makefile.\nExpected:\n{old}"
text = text.replace(old, new, 1)
open(path, 'w').write(text)
PYEOF
    ok "Makefile (gen-btf.sh / PAHOLE_VARIABLES)"
fi

# ─────────────────────────────────────────────────────────────────
# Patch 5: conftest.sh — drm_connector_list_iter version fallback
# ─────────────────────────────────────────────────────────────────
F="${SRC}/conftest.sh"
MARKER='drm_connector_list_iter has been stable since v4.11'
if grep -qF "$MARKER" "$F"; then
    skip "conftest.sh (drm_connector_list_iter fallback)"
else
    backup "$F"
    python3 - "$F" <<'PYEOF'
import sys
path = sys.argv[1]
text = open(path).read()
# The anchor is the first compile_check_conftest call for this symbol,
# followed by the next blank comment line that begins the next sub-test.
old = (
    '            compile_check_conftest "$CODE" "NV_DRM_CONNECTOR_LIST_ITER_PRESENT" "" "types"\n'
    '\n'
    '            #\n'
    '            # Determine if the function drm_connector_list_iter_get() is\n'
)
new = (
    '            compile_check_conftest "$CODE" "NV_DRM_CONNECTOR_LIST_ITER_PRESENT" "" "types"\n'
    '\n'
    '            #\n'
    '            # Fallback: on kernels >= 7.x the drm_connector.h include chain\n'
    '            # pulls in headers that require full kernel CFLAGS (e.g. -mfentry),\n'
    '            # causing the lightweight conftest compile above to fail even though\n'
    '            # drm_connector_list_iter has been stable since v4.11.  Use a\n'
    '            # version-based check with linux/version.h (which is always safe to\n'
    '            # compile in the conftest environment) as a second attempt.  If the\n'
    '            # primary test already succeeded (#define), the extra #define here is\n'
    '            # harmless; if it failed (#undef), the #define below overrides it.\n'
    '            #\n'
    '            CODE="\n'
    '            #include <linux/version.h>\n'
    '            #if LINUX_VERSION_CODE >= KERNEL_VERSION(4, 11, 0)\n'
    '            int conftest_drm_connector_list_iter_version(void) { return 0; }\n'
    '            #else\n'
    '            #error \\"drm_connector_list_iter was added in v4.11\\"\\n'
    '            #endif"\n'
    '\n'
    '            compile_check_conftest "$CODE" "NV_DRM_CONNECTOR_LIST_ITER_PRESENT" "" "types"\n'
    '\n'
    '            #\n'
    '            # Determine if the function drm_connector_list_iter_get() is\n'
)
assert old in text, "Anchor not found in conftest.sh"
text = text.replace(old, new, 1)
open(path, 'w').write(text)
PYEOF
    ok "conftest.sh (drm_connector_list_iter fallback)"
fi

# ─────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo " Patches applied: ${APPLIED}  |  Skipped (already applied): ${SKIPPED}"
echo "========================================"
echo ""

if [[ $APPLIED -eq 0 ]]; then
    info "No new patches applied — skipping DKMS rebuild."
    exit 0
fi

KERNEL="${1:-$(uname -r)}"
info "Rebuilding DKMS module for kernel: ${KERNEL}"
dkms remove  "nvidia-current/${NVIDIA_VER}" --kernelver "${KERNEL}" 2>/dev/null || true
dkms build   "nvidia-current/${NVIDIA_VER}" --kernelver "${KERNEL}"
dkms install "nvidia-current/${NVIDIA_VER}" --kernelver "${KERNEL}"
echo ""
info "Done. Check with: dkms status"
