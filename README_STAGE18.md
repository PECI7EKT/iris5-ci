# Stage 18 — original `msm_drm.ko` baseline on GitHub Actions

**Purpose:** reuse the successful Stage 17 foundation run **#8** (2026-10-18), validate the exact imported kernel CRC, build the necessary out-of-tree Qualcomm/Oplus providers and then build a **completely unmodified** Pixelworks Iris5 Display kernel module. **No flashing or phone operations.** This is an experimental CI job; it has **not yet been executed**.

## Installation in `PECI7EKT/iris5-ci`

Copy **both directories** from the ZIP into the repository root, preserving their paths:

- `.github/workflows/iris5-stage18.yml` (new workflow)
- `ci/stage18/run.sh`
- `ci/stage18/verify_foundation.py`
- `ci/stage18/verify_external.py`
- `ci/stage18/verify_display.py`

The existing `.github/workflows/*`, `ci/reference/*`, `ci/scripts/fetch_sources.sh` and `ci/verify_reference.py` must remain unchanged. When using the GitHub Upload files interface, open the **correct destination folder** first. The leading dot in `.github` may cause the Windows Explorer folder to appear hidden.

## First run — **preflight**

On GitHub go to **Actions → Iris5 6.6.139 - stage18 external providers and baseline → Run workflow → main → preflight**.

The workflow will download the existing artifact `iris5-v2-foundation-8` from run ID `39088927882` using `actions/download-artifact@v4`, restore `out/`, unpack `vmlinux` from zstd, validate the 739 kernel CRC and BTF, check the compiler and `pahole`, and prepare kernel host build tools without doing an external provider build. Attach the resulting `iris5-stage18-preflight-*` artifact if any step fails. This still downloads about 211 MB of foundation artifacts.

If the preflight succeeds, use a **new** run with `baseline`. Do not use "Re-run jobs" on a failed old run to test changed scripts.

## Second run — **baseline**

One fresh Linux runner restores the exact same foundation, builds the external providers in dependency order using the kernel Kbuild, verifies all **24/24** new external CRC against the Stage 16 reference CSV, then attempts to build **unchanged** Display using:

```bash
make -C "$K" O=out ARCH=arm64 LLVM=1 CC='ccache clang' HOSTCC='ccache clang' \
  "M=$DISPLAY_ROOT" "DISPLAY_ROOT=$DISPLAY_ROOT" CONFIG_DRM_MSM=m \
  "KBUILD_EXTRA_SYMBOLS=$GENUINE_SYMVERS" -j2 modules
```

`GENUINE_SYMVERS` is assembled only from provider `Module.symvers` created by real successful provider builds in the *same* job. There is no fake/synthesized symvers. All 763 reference imports, AArch64 architecture, `vermagic`, `.BTF` and presence of KCFI symbols are checked. A successful new compiler exit **does not** certify runtime/hardware safety or the underlying SDR→HDR/MEMC root cause. Full exported symbol/namespace, relocation, CFI-type compatibility and BTF-base equivalence still deserve an independent offline review before any phone test.

The first `baseline` attempt may reveal source/build-script dependency issues; its purpose is to make those issues visible with precise logs, not to hide them using `KBUILD_MODPOST_WARN=1`, fake CRC, disabled CFI, or stripping BTF. Module compilation is fail-closed, with original sources unchanged. Toolchain environment and host tooling follows Stage 17 #8; `pahole v1.27` includes the same one-line initialization backport for the Clang+LTO crash.

## Reproducibility and resource limits

- `Kernel` commit `45174e44b18f5d9024b3024e3de0d48c610b2bb3`.
- `Modules` commit `34e2cb16f16f81d0eec75dde4915d5f139491b4d`.
- `Clang prebuilts` commit `921f6da692b1ffc96a0daa7e741373f0089d40b0`, version Android `11368308/r510928`.
- `dwarves v1.27` commit `3e265dac5ec85b956c664464072196c37d2af4f3` plus the known initialization fix.
- Stage17 `generated_kernel_Module.symvers` SHA `25cd641cd235bb7d010a77a4c6592447186358247e26cf51f99370788f9bc05c`.
- Stage17 `generated_kernel.config` SHA `d921ed3db4681f30371cfabc5b4665e113b317f94fc0d3dc5f45a49338703c5c`.
- Original config differences documented: `CC_CAN_LINK` and `UAPI_HEADER_TEST` only.

The Stage 17 #8 artifact currently expires **2026-11-01** according to GitHub; until the original is retained, the download step can retrieve it. If it expires, re-run the foundation stage and adjust the source artifact run ID rather than creating fake inputs.

Only completed, verified outputs are uploaded as `ci-out/baseline/msm_drm.ko`. Failure still uploads diagnostic logs and per-stage status. No original/vendor reference binary is overwritten, no image ZIP is produced, and no changes are applied to phone or module source.
