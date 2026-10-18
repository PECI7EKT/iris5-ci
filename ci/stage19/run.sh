#!/usr/bin/env bash
# Stage19: OFFLINE ONLY. Never flash/install or hide MODPOST errors.
set -euo pipefail
MODE="${1:-verify}"
[[ "$MODE" == verify || "$MODE" == build ]] || { echo "invalid Stage19 mode: $MODE" >&2; exit 2; }

K="$GITHUB_WORKSPACE/sources/kernel"
MOD="$GITHUB_WORKSPACE/sources/modules"
DR="$MOD/qcom/opensource/display-drivers"
OUT="ci-out/stage19"
PATCH_DIR="$GITHUB_WORKSPACE/ci/stage19/patches"
mkdir -p "$OUT/diagnostics" "$OUT/abi" "$OUT/diffs" "$OUT/modules" "$OUT/logs"

PIN=34e2cb16f16f81d0eec75dde4915d5f139491b4d
KPIN=45174e44b18f5d9024b3024e3de0d48c610b2bb3
git -C "$MOD" checkout --detach "$PIN" > "$OUT/logs/modules_checkout.log" 2>&1
[[ "$(git -C "$MOD" rev-parse HEAD)" == "$PIN" ]] || exit 3
if [[ "$MODE" == build ]]; then
  [[ "$(git -C "$K" rev-parse HEAD)" == "$KPIN" ]] || { echo 'Kernel source mismatch'; exit 3; }
fi

P1="$PATCH_DIR/0001-I1-require-complete-i2c-reads.patch"
P2="$PATCH_DIR/0002-P1-P2-propagate-pt-esd-read-errors.patch"
P3="$PATCH_DIR/0003-P3-reject-pt-fifo-without-received.patch"
P4="$PATCH_DIR/0004-P4-bound-pt-response-length.patch"
P5="$PATCH_DIR/0005-P5-66-limit-esd-diagnostics-to-valid-data.patch"
D1="$PATCH_DIR/0006-D1-review-only-ssc-configure-readback.patch"
for p in "$P1" "$P2" "$P3" "$P4" "$P5" "$D1"; do
  [[ -s "$p" ]] || { echo "Missing $p"; exit 3; }
done
sha256sum "$P1" "$P2" "$P3" "$P4" "$P5" "$D1" > "$OUT/patch_sha256.txt"

restore_display() {
  git -C "$MOD" restore --source=HEAD --worktree -- qcom/opensource/display-drivers
}
apply_one() {
  local label="$1" patch="$2" action="$3"
  local args=(--whitespace=error-all)
  if [[ "$label" == D1 ]]; then
    # D1 was produced relative to display-drivers/msm, unlike the other patches.
    args+=(--directory=qcom/opensource/display-drivers/msm)
  fi
  if [[ "$action" == check ]]; then
    git -C "$MOD" -c core.autocrlf=false apply --check "${args[@]}" "$patch"
  else
    git -C "$MOD" -c core.autocrlf=false apply "${args[@]}" "$patch"
  fi
}

# Variants are intentional and independent. P5 is ONLY paired with P1/P2;
# D1 is diagnostic only and not combined with functional changes.
variants=(I1 P1P2 P3 P4 P1P2_P5 I1_P1P2_P3_P4_P5 D1)
variant_patches() {
  case "$1" in
    I1) chosen=(I1);;
    P1P2) chosen=(P1P2);;
    P3) chosen=(P3);;
    P4) chosen=(P4);;
    P1P2_P5) chosen=(P1P2 P5);;
    I1_P1P2_P3_P4_P5) chosen=(I1 P1P2 P3 P4 P5);;
    D1) chosen=(D1);;
    *) echo "Unknown variant $1" >&2; exit 2;;
  esac
}
patch_path() {
  case "$1" in
    I1) printf '%s' "$P1";;
    P1P2) printf '%s' "$P2";;
    P3) printf '%s' "$P3";;
    P4) printf '%s' "$P4";;
    P5) printf '%s' "$P5";;
    D1) printf '%s' "$D1";;
  esac
}

check_variant() {
  local label="$1" step patch
  local log="$OUT/logs/apply_${label}.log"
  variant_patches "$label"
  restore_display
  : > "$log"
  for step in "${chosen[@]}"; do
    patch="$(patch_path "$step")"
    echo "CHECK $label/$step $(sha256sum "$patch")" >> "$log"
    if ! apply_one "$step" "$patch" check >> "$log" 2>&1; then
      echo "BLOCKED: git apply --check $label/$step" | tee -a "$log"
      restore_display
      return 1
    fi
    if ! apply_one "$step" "$patch" apply >> "$log" 2>&1; then
      echo "BLOCKED: git apply $label/$step" | tee -a "$log"
      restore_display
      return 1
    fi
  done
  if ! git -C "$MOD" diff --check -- qcom/opensource/display-drivers >> "$log" 2>&1; then
    echo "BLOCKED: git diff --check $label" | tee -a "$log"
    restore_display
    return 1
  fi
  git -C "$MOD" diff --binary -- qcom/opensource/display-drivers > "$OUT/diffs/${label}.diff"
  printf '%s\n' "APPLY PASS: $label" | tee -a "$OUT/progress.txt"
  restore_display
}

printf 'Stage19 source=%s mode=%s (OFFLINE ONLY)\n' "$PIN" "$MODE" | tee "$OUT/progress.txt"
failed=0
for label in "${variants[@]}"; do
  if ! check_variant "$label"; then failed=$((failed + 1)); fi
done
restore_display
if (( failed )); then
  printf 'BLOCKED: %s patch variants failed textual check; build not attempted\n' "$failed" | tee -a "$OUT/progress.txt"
  exit 4
fi
if [[ "$MODE" == verify ]]; then
  echo 'STAGE19 PATCH VERIFICATION PASS (not yet compiled or installed)' | tee -a "$OUT/progress.txt"
  exit 0
fi

# Previous step ran stage18/run.sh baseline in THIS job. Its output is our
# reference; external providers are compiled in dependency order and persist.
[[ -s ci-out/baseline/msm_drm.ko ]] || { echo 'Missing authenticated Stage18 baseline module'; exit 5; }
[[ -s ci-out/baseline_abi.json ]] || { echo 'Missing Stage18 baseline ABI audit'; exit 5; }
cp ci-out/baseline_abi.json "$OUT/original_baseline_abi.json"
cp ci-out/baseline/msm_drm.sha256 "$OUT/original_baseline.sha256"

export PATH="$GITHUB_WORKSPACE/prebuilts/clang/host/linux-x86/clang-r510928/bin:$GITHUB_WORKSPACE/.ci-tools/dwarves-install/bin:$PATH"
export LD_LIBRARY_PATH="$GITHUB_WORKSPACE/.ci-tools/dwarves-install/lib:${LD_LIBRARY_PATH:-}"
export LLVM=1 LLVM_IAS=1 ARCH=arm64 SUBARCH=arm64 CCACHE_DISABLE=1
command -v clang > "$OUT/clang_path.txt"
command -v pahole > "$OUT/pahole_path.txt"

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
  [[ -s "$f" ]] || { echo "Missing genuine external symbols $f" >&2; exit 5; }
  SYM_FILES+=("$f")
done
SYMS="${SYM_FILES[*]}"

for label in "${variants[@]}"; do
  echo "BUILD $label" | tee -a "$OUT/progress.txt"
  restore_display
  # For every variant, ensure no object files from any previous Display build.
  if ! make -C "$K" O=out ARCH=arm64 LLVM=1 CC='ccache clang' HOSTCC='ccache clang' \
       "M=$DR" "DISPLAY_ROOT=$DR" CONFIG_DRM_MSM=m clean \
       > "$OUT/logs/clean_${label}.log" 2>&1; then
    echo "FAIL: clean $label" | tee -a "$OUT/progress.txt"
    failed=$((failed + 1)); continue
  fi
  variant_patches "$label"
  ok=1
  for step in "${chosen[@]}"; do
    patch="$(patch_path "$step")"
    if ! apply_one "$step" "$patch" check > "$OUT/logs/build_apply_${label}_${step}.log" 2>&1 ||
       ! apply_one "$step" "$patch" apply >> "$OUT/logs/build_apply_${label}_${step}.log" 2>&1; then
      echo "FAIL: apply $label/$step" | tee -a "$OUT/progress.txt"
      failed=$((failed + 1)); ok=0; break
    fi
  done
  if (( !ok )); then restore_display; continue; fi
  git -C "$MOD" diff --binary -- qcom/opensource/display-drivers > "$OUT/diffs/build_${label}.diff"
  if make -C "$K" O=out ARCH=arm64 LLVM=1 CC='ccache clang' HOSTCC='ccache clang' \
      "M=$DR" "DISPLAY_ROOT=$DR" CONFIG_DRM_MSM=m \
      "KBUILD_EXTRA_SYMBOLS=$SYMS" -j2 modules > "$OUT/logs/compile_${label}.log" 2>&1; then
    :
  else
    echo "FAIL: compile $label" | tee -a "$OUT/progress.txt"
    failed=$((failed + 1)); restore_display; continue
  fi
  ko="$DR/msm/msm_drm.ko"
  if [[ ! -s "$ko" ]]; then
    echo "FAIL: no msm_drm.ko for $label" | tee -a "$OUT/progress.txt"
    failed=$((failed + 1)); restore_display; continue
  fi
  if python3 ci/stage19/verify_variant.py "$label" "$ko" \
       > "$OUT/logs/abi_${label}.log" 2>&1; then
    cp "$ko" "$OUT/modules/${label}_msm_drm.ko"
    echo "BUILD+ABI PASS: $label" | tee -a "$OUT/progress.txt"
  else
    echo "FAIL: ABI $label" | tee -a "$OUT/progress.txt"
    failed=$((failed + 1))
  fi
  restore_display
done
restore_display
cp "$OUT/original_baseline_abi.json" ci-out/baseline_abi.json
if (( failed )); then
  echo "BLOCKED: $failed variant(s) failed. Examine ci-out/stage19/logs and abi." | tee -a "$OUT/progress.txt"
  exit 7
fi
printf 'STAGE19 BUILD+ABI PASS: %s isolated variants. OFFLINE ONLY / NOT APPROVED FOR FLASH.\n' "${#variants[@]}" | tee -a "$OUT/progress.txt"
