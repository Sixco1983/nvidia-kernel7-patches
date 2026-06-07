# NVIDIA 550 — Kernel 7.x Compatibility Patches

Patches and apt hook to compile **nvidia-current 550.163.01** DKMS against **Linux kernel 7.x** on Debian/Parrot Linux.

NVIDIA 550 was released before kernel 7.x; these fixes bridge the API gaps until upstream ships an official patch.

## Files

| File | Purpose |
|------|---------|
| `nvidia-patch-kernel7.sh` | Applies the 5 source patches and rebuilds the DKMS module |
| `99nvidia-kernel7-patch` | apt `DPkg::Post-Invoke` hook — reruns the script automatically after any nvidia-kernel-dkms upgrade |

## Patches applied

| # | File | Problem | Fix |
|---|------|---------|-----|
| 1 | `common/inc/nv-mm.h` | `VMA_LOCK_OFFSET` renamed to `VM_REFCNT_EXCLUDE_READERS_FLAG` in kernel 7.x | Compat `#define` |
| 2 | `nvidia/nv-mmap.c` | `__is_vma_write_locked()` changed from 2 args to 1 arg | `#if` guard; read `mm_lock_seq` separately |
| 3 | `nvidia-drm/nvidia-dma-fence-helper.h` | `dma_fence_signal()` return type changed from `int` to `void` | Call without capturing return; explicit `return 0` |
| 4 | `Makefile` | Kernel 7.x replaced `scripts/pahole-flags.sh` with `scripts/gen-btf.sh` | Check for either file in `PAHOLE_VARIABLES` condition |
| 5 | `conftest.sh` | `drm_connector.h` include chain pulls in headers requiring full kernel CFLAGS, causing `NV_DRM_CONNECTOR_LIST_ITER_PRESENT` to be left `#undef`ed → spurious `WARN_ON` in dmesg | Add version-based fallback using `linux/version.h` for kernels ≥ 4.11 |

## Installation

```bash
# 1. Apply patches and rebuild DKMS for the running kernel
sudo bash nvidia-patch-kernel7.sh

# 2. Install the apt hook so patches reapply automatically after upgrades
sudo cp 99nvidia-kernel7-patch /etc/apt/apt.conf.d/
```

The script is idempotent — safe to run multiple times. It skips already-applied patches and only triggers a DKMS rebuild when something actually changed.

## Tested on

- **OS:** Parrot Security 7.2 (Debian-based)
- **GPU:** NVIDIA RTX 2070
- **Driver:** nvidia-current 550.163.01
- **Kernels:** 6.19.13+parrot7-amd64 and 7.0.9+parrot7-amd64
