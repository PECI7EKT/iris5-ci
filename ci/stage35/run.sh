#!/usr/bin/env bash
# Stage35: exact Stage29 diagnostics plus opt-in DSI pulse, OFF by default.
# Source verification and offline target build ONLY. No device operations.
set -euo pipefail
MODE="${1:-verify}"
[[ "$MODE" == verify || "$MODE" == build ]] || { echo "Bad mode: $MODE" >&2; exit 2; }
K="$GITHUB_WORKSPACE/sources/kernel"
MOD="$GITHUB_WORKSPACE/sources/modules"
DR="$MOD/qcom/opensource/display-drivers"
OUT="$GITHUB_WORKSPACE/ci-out/stage35"
PIN='34e2cb16f16f81d0eec75dde4915d5f139491b4d'
KPIN='45174e44b18f5d9024b3024e3de0d48c610b2bb3'
I1="$GITHUB_WORKSPACE/ci/stage19/patches/0001-I1-require-complete-i2c-reads.patch"
SSC="$GITHUB_WORKSPACE/ci/stage22/patches/0001-SSC-honor-oplus-disable.patch"
mkdir -p "$OUT"/logs "$OUT"/diffs "$OUT"/modules "$OUT"/abi
exec > >(tee "$OUT/logs/stage35.log") 2>&1
DIAG="$GITHUB_WORKSPACE/ci/stage23/patches/0001-stage23-readonly-dphy-ssc-diagnostics.patch"
ESD="$GITHUB_WORKSPACE/ci/stage24/patches/0001-pt-esd-readonly-trace.patch"
I25="$GITHUB_WORKSPACE/ci/stage25/patches/0001-stage25-i2c-s-write-result-trace.patch"
I26="$GITHUB_WORKSPACE/ci/stage26/patches/0001-stage26-dcs-header-host-send-trace.patch"
I27="$GITHUB_WORKSPACE/ci/stage27/patches/0001-stage27-wake-gpio-abyp-sequence-trace.patch"
I28="$GITHUB_WORKSPACE/ci/stage28/apply_fix.py"
I29="$GITHUB_WORKSPACE/ci/stage29/apply_fix.py"
I33="$GITHUB_WORKSPACE/ci/stage33/apply_fix.py"
I34="$GITHUB_WORKSPACE/ci/stage34/apply_irq_diag.py"
I35="$GITHUB_WORKSPACE/ci/stage35/apply.py"
for f in "$I1" "$SSC" "$DIAG" "$ESD" "$I25" "$I26" "$I27" "$I28" "$I29" "$I33" "$I34" "$I35"; do [[ -s "$f" ]] || { echo "BLOCKED: missing $f"; exit 3; }; done
echo 'd4a4b0f2a5c796ad642f3c61751b685474dd48750ce740061ce718ed4fcc223b  '"$I1" | sha256sum -c -
sha256sum "$I1" "$SSC" "$DIAG" "$ESD" "$I25" "$I26" "$I27" "$I28" "$I29" "$I33" "$I34" "$I35" > "$OUT/patches.sha256"
git -C "$MOD" checkout --detach "$PIN"
[[ "$(git -C "$MOD" rev-parse HEAD)" == "$PIN" ]] || exit 3
[[ "$MODE" != build || "$(git -C "$K" rev-parse HEAD)" == "$KPIN" ]] || { echo 'BLOCKED: kernel pin mismatch'; exit 3; }
restore_display() { git -C "$MOD" restore --source=HEAD --worktree -- qcom/opensource/display-drivers; }
trap restore_display EXIT
apply_patches() {
  for p in "$I1" "$SSC" "$DIAG" "$ESD" "$I25" "$I26" "$I27"; do
    git -C "$MOD" -c core.autocrlf=false apply --check --whitespace=error-all "$p"
    git -C "$MOD" -c core.autocrlf=false apply --whitespace=error-all "$p"
  done
  python3 "$I28" "$DR"
  python3 "$I29" "$DR"
  python3 "$I33" "$DR"
  python3 "$I34" "$DR"
  python3 "$I35" "$DR"
  git -C "$MOD" diff --check -- qcom/opensource/display-drivers
  local actual expected
  actual="$(git -C "$MOD" diff --name-only -- qcom/opensource/display-drivers | LC_ALL=C sort)"
  expected="$(printf '%s\n' \
    'qcom/opensource/display-drivers/msm/dsi/dsi_panel.c' \
    'qcom/opensource/display-drivers/msm/dsi/dsi_pll.c' \
    'qcom/opensource/display-drivers/msm/dsi/dsi_pll_5nm.c' \
    'qcom/opensource/display-drivers/msm/iris/iris5/dsi_iris5_gpio.c' \
    'qcom/opensource/display-drivers/msm/iris/iris5/dsi_iris5_lp.c' \
    'qcom/opensource/display-drivers/msm/iris/iris5/dsi_iris5_lightup.c' \
    'qcom/opensource/display-drivers/msm/iris/iris5/dsi_iris5_lightup_ocp.c' \
    'qcom/opensource/display-drivers/msm/iris/iris5/dsi_iris5_ioctl.c' \
    'qcom/opensource/display-drivers/msm/iris/iris5/dsi_iris5_i2c.c' \
    'qcom/opensource/display-drivers/msm/iris/iris5/dsi_iris5_loop_back.c' \
    'qcom/opensource/display-drivers/msm/sde/sde_encoder.c' \
    'qcom/opensource/display-drivers/msm/sde/sde_encoder_phys_cmd.c' | LC_ALL=C sort)"
  if [[ "$actual" != "$expected" ]]; then
    echo 'BLOCKED: unexpected source diff:'
    printf '%s\n' "$actual"
    exit 4
  fi
  git -C "$MOD" diff --binary -- qcom/opensource/display-drivers > "$OUT/diffs/I1_plus_SSC_pt_esd_i2c_ptchecked.diff"
  test -s "$OUT/diffs/I1_plus_SSC_pt_esd_i2c_ptchecked.diff"
  grep -qF 'oplus,dsi-pll-ssc-disalbed' "$DR/msm/dsi/dsi_pll.c"
  grep -qF 'PLL SSC disabled by Oplus DT override' "$DR/msm/dsi/dsi_pll.c"
  grep -qF 'IRIS23_DPHY' "$DR/msm/iris/iris5/dsi_iris5_lp.c"
  grep -qF 'IRIS23_SSC' "$DR/msm/dsi/dsi_pll_5nm.c"
  grep -qF 'IRIS24_INTSTAT' "$DR/msm/iris/iris5/dsi_iris5_lightup_ocp.c"
  grep -qF 'IRIS24_RXDATA' "$DR/msm/iris/iris5/dsi_iris5_lightup_ocp.c"
  grep -qF 'IRIS24_REJECT_TYPE' "$DR/msm/iris/iris5/dsi_iris5_ioctl.c"
  grep -qF 'IRIS25_I2C_S_WRITE' "$DR/msm/iris/iris5/dsi_iris5_lightup.c"
  grep -qF 'IRIS26_DCS_HEADER' "$DR/msm/iris/iris5/dsi_iris5_lightup_ocp.c"
  grep -qF 'IRIS26_OCP_HOST_SEND' "$DR/msm/iris/iris5/dsi_iris5_lightup_ocp.c"
  grep -qF 'IRIS27_ONEWIRE_DONE' "$DR/msm/iris/iris5/dsi_iris5_gpio.c"
  grep -qF 'IRIS27_RESET_DONE' "$DR/msm/iris/iris5/dsi_iris5_gpio.c"
  grep -qF 'IRIS27_EXIT_ATTEMPT' "$DR/msm/iris/iris5/dsi_iris5_lp.c"
  grep -qF 'mutex_lock(&panel->panel_tx_lock)' "$DR/msm/dsi/dsi_panel.c"
  grep -qF 'mutex_init(&panel->panel_tx_lock)' "$DR/msm/dsi/dsi_panel.c"
  grep -qF 'STAGE28_PT_RX_TIMEOUT' "$DR/msm/iris/iris5/dsi_iris5_lightup_ocp.c"
  grep -qF 'return _iris_pt_write_panel_cmd(panel, cmdset)' "$DR/msm/iris/iris5/dsi_iris5_lightup_ocp.c"
  grep -qF 'IRIS29_PT_RX_I2C_FAIL' "$DR/msm/iris/iris5/dsi_iris5_lightup_ocp.c"
  grep -qF 'IRIS33_PULSE_BEGIN' "$DR/msm/iris/iris5/dsi_iris5_lp.c"
  grep -qF 'module_param_named(iris33_postreset_pulse' "$DR/msm/iris/iris5/dsi_iris5_lp.c"
  grep -qF 'module_param_named(iris34_irq_diag' "$DR/msm/sde/sde_encoder.c"
  grep -qF 'IRIS34_IRQ_WAIT_POST' "$DR/msm/sde/sde_encoder.c"
  grep -qF 'IRIS34_IRQ_UNREGISTER' "$DR/msm/sde/sde_encoder.c"
  grep -qF 'module_param_named(iris35_vblank_diag' "$DR/msm/sde/sde_encoder_phys_cmd.c"
  grep -qF 'IRIS35_WAIT_BEGIN' "$DR/msm/sde/sde_encoder_phys_cmd.c"
  grep -qF 'IRIS35_VBLANK_CALL' "$DR/msm/sde/sde_encoder.c"
  grep -qF 'iris_i2c_conver_ocp_read(&v, 1, false)' "$DR/msm/iris/iris5/dsi_iris5_lightup_ocp.c"
  echo 'STAGE35 SOURCE CHECK PASS: Stage34 unchanged plus opt-in RDPTR callback/wait diagnostics'
}
restore_display
apply_patches
restore_display
if [[ "$MODE" == verify ]]; then
  echo 'STAGE35 VERIFY PASS (NOT COMPILED; NOT DEVICE TESTED)'
  exit 0
fi
# Stage18 baseline must have been built in this SAME job from the pinned
# foundation; external provider Module.symvers files remain available.
[[ -s "$GITHUB_WORKSPACE/ci-out/baseline/msm_drm.ko" && -s "$GITHUB_WORKSPACE/ci-out/baseline_abi.json" ]] || {
  echo 'BLOCKED: verified Stage18 baseline missing'; exit 5;
}
cp "$GITHUB_WORKSPACE/ci-out/baseline_abi.json" "$OUT/abi/baseline.json"
export PATH="$GITHUB_WORKSPACE/prebuilts/clang/host/linux-x86/clang-r510928/bin:$GITHUB_WORKSPACE/.ci-tools/dwarves-install/bin:$PATH"
export LD_LIBRARY_PATH="$GITHUB_WORKSPACE/.ci-tools/dwarves-install/lib:${LD_LIBRARY_PATH:-}"
export LLVM=1 LLVM_IAS=1 ARCH=arm64 SUBARCH=arm64 CCACHE_DISABLE=1
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
  [[ -s "$f" ]] || { echo "BLOCKED: missing provider symvers $f"; exit 5; }
  SYM_FILES+=("$f")
done
SYMS="${SYM_FILES[*]}"
make -C "$K" O=out ARCH=arm64 LLVM=1 CC='ccache clang' HOSTCC='ccache clang' \
  "M=$DR" "DISPLAY_ROOT=$DR" CONFIG_DRM_MSM=m clean > "$OUT/logs/clean.log" 2>&1
apply_patches
make -C "$K" O=out ARCH=arm64 LLVM=1 CC='ccache clang' HOSTCC='ccache clang' \
  "M=$DR" "DISPLAY_ROOT=$DR" CONFIG_DRM_MSM=m \
  "KBUILD_EXTRA_SYMBOLS=$SYMS" -j2 modules > "$OUT/logs/compile.log" 2>&1
KO="$DR/msm/msm_drm.ko"
[[ -s "$KO" ]] || { echo 'BLOCKED: missing compiled msm_drm.ko'; exit 5; }
python3 "$GITHUB_WORKSPACE/ci/stage18/verify_display.py" "$KO" > "$OUT/logs/verify_abi.log" 2>&1 || {
  cp "$GITHUB_WORKSPACE/ci-out/baseline_abi.json" "$OUT/abi/failure.json" 2>/dev/null || true
  echo 'BLOCKED: Stage18 ABI verifier failed'; exit 6;
}
cp "$GITHUB_WORKSPACE/ci-out/baseline_abi.json" "$OUT/abi/I1_plus_SSC_diag.json"
cp "$OUT/abi/baseline.json" "$GITHUB_WORKSPACE/ci-out/baseline_abi.json"
sha256sum "$KO" "$GITHUB_WORKSPACE/ci-out/baseline/msm_drm.ko" > "$OUT/module_sha256.txt"
[[ "$(sha256sum "$KO" | cut -d' ' -f1)" != '700460af78f1cb6f184b28ed768ca33a8d271ecad83bb0be672e5eca6fb2ae99' ]] || {
  echo 'BLOCKED: Stage34 unexpectedly matches pinned Stage21 I1 binary'; exit 7;
}
cp "$KO" "$OUT/modules/Stage35_RDPTR_TE_DIAG_msm_drm.ko"
restore_display
printf '%s\n' 'STAGE35 BUILD+ABI PASS (OFFLINE MODULE ONLY; NOT FLASH APPROVED)'

