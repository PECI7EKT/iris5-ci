#!/usr/bin/env bash
# Full external display module; no image/installer/repack/sign/phone operations.
set -euo pipefail
K="$GITHUB_WORKSPACE/sources/kernel"
MOD="$GITHUB_WORKSPACE/sources/modules"
DR="$MOD/qcom/opensource/display-drivers"
OUT="$GITHUB_WORKSPACE/ci-out/stage50b"
SCRIPT="$GITHUB_WORKSPACE/ci/stage50b"
mkdir -p "$OUT"/{logs,modules,abi,config,symbols,diffs,source}
exec > >(tee "$OUT/logs/stage50b.log") 2>&1
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
cp "$GITHUB_WORKSPACE/ci-out/stage44/modules/STAGE44_DIAGNOSTIC_msm_drm.ko" "$OUT/modules/STAGE44_BASELINE_msm_drm.ko"
cp "$GITHUB_WORKSPACE/ci-out/stage44/abi/authentic_providers.json" "$OUT/abi/authentic_providers.json"
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
python3 - <<'PY'
from pathlib import Path
import hashlib,json,os
root=Path(os.environ['GITHUB_WORKSPACE'])
m=json.loads((root/'ci/stage44/source_manifest.json').read_text())
assert hashlib.sha256((root/'ci-out/stage44/modules/STAGE44_DIAGNOSTIC_msm_drm.ko').read_bytes()).hexdigest()=='f1239ce975972d43390a8a377eed6ddee59d3022f8b60223eaed51f45019947b', 'baseline Stage44 not bit-identical: investigate before candidate'
PY
git -C "$MOD" -c core.autocrlf=false apply --check "$SCRIPT/stage50b_observe_only.patch"
git -C "$MOD" -c core.autocrlf=false apply "$SCRIPT/stage50b_observe_only.patch"
python3 - <<'PY'
from pathlib import Path
import hashlib,json,os
root=Path(os.environ['GITHUB_WORKSPACE']);m=json.loads((root/'ci/stage50b/source_manifest.json').read_text())
for p,h in m.items():assert hashlib.sha256((root/'sources/modules'/p).read_bytes()).hexdigest()==h,p
(root/'ci-out/stage50b/source/stage50b.json').write_text(json.dumps({'files':m,'verified_files':len(m)},indent=2)+'\n')
print('Stage50B exact 460 source hashes PASS')
PY
git -C "$MOD" diff --check -- qcom/opensource/display-drivers
git -C "$MOD" diff --binary -- qcom/opensource/display-drivers > "$OUT/diffs/stage50b_cumulative.diff"
cp "$SCRIPT/stage50b_observe_only.patch" "$OUT/diffs/"
cp "$SCRIPT/source_manifest.json" "$OUT/source/"
printf '%q ' make -C "$K" O=out ARCH=arm64 LLVM=1 CC='ccache clang' HOSTCC='ccache clang' \
  "M=$DR" "DISPLAY_ROOT=$DR" CONFIG_DRM_MSM=m "KBUILD_EXTRA_SYMBOLS=$SYMS" -j2 modules > "$OUT/logs/build_command.txt"
printf '\n' >> "$OUT/logs/build_command.txt"
make -C "$K" O=out ARCH=arm64 LLVM=1 CC='ccache clang' HOSTCC='ccache clang' \
  "M=$DR" "DISPLAY_ROOT=$DR" CONFIG_DRM_MSM=m "KBUILD_EXTRA_SYMBOLS=$SYMS" -j2 modules > "$OUT/logs/compile.log" 2>&1
KO="$DR/msm/msm_drm.ko"
[[ -s "$KO" ]]
cp "$KO" "$OUT/modules/STAGE50B_OBSERVE_msm_drm.ko"
cp "$DR/Module.symvers" "$OUT/symbols/stage50b.Module.symvers"
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
echo 'STAGE50B FULL MODULE BUILD + STATIC ABI VALIDATION PASS; NOT DEVICE TESTED'
