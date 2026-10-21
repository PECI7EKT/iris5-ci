#!/usr/bin/env bash
# Full external display module; no image/installer/repack/sign/phone operations.
set -euo pipefail
K="$GITHUB_WORKSPACE/sources/kernel"
MOD="$GITHUB_WORKSPACE/sources/modules"
DR="$MOD/qcom/opensource/display-drivers"
OUT="$GITHUB_WORKSPACE/ci-out/stage44"
SCRIPT="$GITHUB_WORKSPACE/ci/stage44"
mkdir -p "$OUT"/{logs,modules,abi,config,symbols,diffs,source}
exec > >(tee "$OUT/logs/stage44.log") 2>&1
on_exit() {
  local rc=$?
  printf '%s\n' "$rc" > "$OUT/exit_code.txt"
  if ((rc)); then tail -n 120 "$OUT/logs/compile.log" 2>/dev/null || true; fi
}
trap on_exit EXIT
[[ "$(git -C "$K" rev-parse HEAD)" == 45174e44b18f5d9024b3024e3de0d48c610b2bb3 ]]
[[ "$(git -C "$MOD" rev-parse HEAD)" == 34e2cb16f16f81d0eec75dde4915d5f139491b4d ]]
[[ -s "$K/out/vmlinux" && -s "$K/out/include/generated/autoconf.h" ]]
python3 ci/stage18/verify_foundation.py
export PATH="$GITHUB_WORKSPACE/prebuilts/clang/host/linux-x86/clang-r510928/bin:$GITHUB_WORKSPACE/.ci-tools/dwarves-install/bin:$PATH"
export LD_LIBRARY_PATH="$GITHUB_WORKSPACE/.ci-tools/dwarves-install/lib:${LD_LIBRARY_PATH:-}"
export LLVM=1 LLVM_IAS=1 ARCH=arm64 SUBARCH=arm64 CCACHE_DISABLE=1
clang --version > "$OUT/config/clang.txt"
ld.lld --version > "$OUT/config/lld.txt"
pahole --version > "$OUT/config/pahole.txt"
sha256sum "$(command -v clang)" "$(command -v ld.lld)" > "$OUT/config/compiler_sha256.txt"
cp "$K/out/.config" "$OUT/config/kernel.config"
cp "$K/out/Module.symvers" "$OUT/symbols/kernel.Module.symvers"
cp "$GITHUB_WORKSPACE/ci-out/foundation_restored.json" "$OUT/config/foundation_restored.json"
sha256sum "$K/out/vmlinux" > "$OUT/config/vmlinux.sha256"
cp "$GITHUB_WORKSPACE/ci-out/stage36/modules/Stage36_VBLANK_GUARD_msm_drm.ko" "$OUT/modules/STAGE36_REBUILT_msm_drm.ko"
cp "$GITHUB_WORKSPACE/stage36-reference/modules/Stage36_VBLANK_GUARD_msm_drm.ko" "$OUT/modules/STAGE36_REFERENCE_msm_drm.ko"
cp "$DR/Module.symvers" "$OUT/symbols/stage36.Module.symvers"
cp "$GITHUB_WORKSPACE/ci-out/stage36/diffs/I1_plus_SSC_pt_esd_i2c_ptchecked.diff" "$OUT/diffs/stage36_cumulative.diff"
echo 'e874026e950dee56ce760ad1ce86b0f1825aebe154fe930b32c921545f9e3189  '"$OUT/diffs/stage36_cumulative.diff" | sha256sum -c -
SYM_PATHS=(
  oplus/kernel/boot/cmdline_parser
  oplus/kernel/boot/bootmode
  oplus/kernel/boot/oplus_projectinfo
  oplus/kernel/device_info/device_info
  oplus/kernel/touchpanel/touchpanel_notify
  qcom/opensource/securemsm-kernel
  qcom/opensource/mm-drivers/msm_ext_display
  qcom/opensource/mmrm-driver
)
SYM_FILES=()
for rel in "${SYM_PATHS[@]}"; do
  f="$MOD/$rel/Module.symvers"
  [[ -s "$f" ]]
  SYM_FILES+=("$f")
  label="${rel//\//_}"
  cp "$f" "$OUT/symbols/$label.Module.symvers"
done
SYMS="${SYM_FILES[*]}"
make -C "$K" O=out ARCH=arm64 LLVM=1 CC='ccache clang' HOSTCC='ccache clang' \
  "M=$DR" "DISPLAY_ROOT=$DR" CONFIG_DRM_MSM=m clean > "$OUT/logs/clean.log" 2>&1
# Stage36 run restores the original display sources after building. Apply its
# exact verified diff; this does not execute packaging or add Stage42 changes.
git -C "$MOD" -c core.autocrlf=false apply --check "$OUT/diffs/stage36_cumulative.diff"
git -C "$MOD" -c core.autocrlf=false apply "$OUT/diffs/stage36_cumulative.diff"
python3 "$SCRIPT/verify_source.py" "$MOD" stage36 "$OUT/source/stage36.json"
git -C "$MOD" -c core.autocrlf=false apply --check "$SCRIPT/stage44_abyp_host_diag.patch"
git -C "$MOD" -c core.autocrlf=false apply "$SCRIPT/stage44_abyp_host_diag.patch"
python3 "$SCRIPT/verify_source.py" "$MOD" stage44 "$OUT/source/stage44.json"
git -C "$MOD" -c core.autocrlf=false add -N qcom/opensource/display-drivers/msm/iris_host_diag.h
git -C "$MOD" diff --check -- qcom/opensource/display-drivers
git -C "$MOD" diff --binary -- qcom/opensource/display-drivers > "$OUT/diffs/stage44_cumulative.diff"
cp "$SCRIPT/stage44_abyp_host_diag.patch" "$OUT/diffs/"
cp "$SCRIPT/source_manifest.json" "$OUT/source/"
printf '%q ' make -C "$K" O=out ARCH=arm64 LLVM=1 CC='ccache clang' HOSTCC='ccache clang' \
  "M=$DR" "DISPLAY_ROOT=$DR" CONFIG_DRM_MSM=m "KBUILD_EXTRA_SYMBOLS=$SYMS" -j2 modules > "$OUT/logs/build_command.txt"
printf '\n' >> "$OUT/logs/build_command.txt"
make -C "$K" O=out ARCH=arm64 LLVM=1 CC='ccache clang' HOSTCC='ccache clang' \
  "M=$DR" "DISPLAY_ROOT=$DR" CONFIG_DRM_MSM=m "KBUILD_EXTRA_SYMBOLS=$SYMS" -j2 modules > "$OUT/logs/compile.log" 2>&1
KO="$DR/msm/msm_drm.ko"
[[ -s "$KO" ]]
cp "$KO" "$OUT/modules/STAGE44_DIAGNOSTIC_msm_drm.ko"
cp "$DR/Module.symvers" "$OUT/symbols/stage44.Module.symvers"
for f in "$DR"/msm/.msm_drm*.cmd; do
  if [[ -f "$f" ]]; then
    label="${f##*/}"
    cp "$f" "$OUT/config/${label#.}"
  fi
done
for rel in iris/iris5/.dsi_iris5_lp.o.cmd iris/iris5/.dsi_iris5_gpio.o.cmd dsi/.dsi_clk_manager.o.cmd dsi/.dsi_phy.o.cmd dsi/.dsi_pll_5nm.o.cmd sde/.sde_kms.o.cmd; do
  f="$DR/msm/$rel"
  [[ -s "$f" ]]
  label="${f##*/}"
  cp "$f" "$OUT/config/${label#.}"
done
sha256sum "$OUT/modules/"*.ko > "$OUT/module_sha256.txt"
python3 "$SCRIPT/verify_binary.py" "$OUT"
echo 'STAGE44 FULL MODULE BUILD + STATIC ABI VALIDATION PASS; NOT DEVICE TESTED'
