#!/usr/bin/env bash
# Stage18: consume *genuine* successful Stage17 foundation artifact #8.
# NEVER flash, install, weaken MODVERSIONS/CFI/BTF, or create forged Module.symvers.
set -euo pipefail
MODE="${1:-preflight}"
[[ "$MODE" == preflight || "$MODE" == baseline ]] || { echo "Unsupported mode: $MODE" >&2; exit 2; }
mkdir -p ci-out/stage18-logs
on_exit() {
  local rc=$?
  printf '%s\n' "$rc" > ci-out/stage18_exit_code.txt
  { date -u; df -h .; free -h; } > ci-out/stage18_resources_final.txt 2>&1 || true
}
trap on_exit EXIT

note() { printf '%s\n' "$*" | tee -a ci-out/stage18_progress.txt; }
fail() { note "BLOCKED: $*"; exit 4; }
K="$GITHUB_WORKSPACE/sources/kernel"
MOD="$GITHUB_WORKSPACE/sources/modules"
Q="$MOD/qcom/opensource"
O="$MOD/oplus"
ART="$GITHUB_WORKSPACE/stage18-foundation"
J=2

note "STAGE18 mode=$MODE / stage17 foundation run=39088927882"
note '--- INSTALL NECESSARY BUILD TOOLS ---'
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  build-essential bc bison flex ccache cmake pkg-config libbpf-dev libdw-dev \
  libelf-dev libssl-dev zlib1g-dev zstd lz4 cpio rsync python3-pyelftools \
  binutils kmod git ca-certificates gcc-aarch64-linux-gnu libc6-dev-arm64-cross

note '--- CHECK OUT PINNED SOURCES ---'
git -C "$K" checkout --detach 45174e44b18f5d9024b3024e3de0d48c610b2bb3
git -C "$MOD" checkout --detach 34e2cb16f16f81d0eec75dde4915d5f139491b4d
[[ "$(git -C "$K" rev-parse HEAD)" == 45174e44b18f5d9024b3024e3de0d48c610b2bb3 ]] || fail 'kernel SHA mismatch'
[[ "$(git -C "$MOD" rev-parse HEAD)" == 34e2cb16f16f81d0eec75dde4915d5f139491b4d ]] || fail 'module SHA mismatch'
for h in touchpanel_event_notify.h device_info.h kernelFwUpdate.h; do
  [[ -f "$K/include/soc/oplus/$h" ]] || fail "broken kernel Oplus header symlink: $h"
done

note '--- RESTORE VERIFIED GENERATED KERNEL OUTPUT ---'
[[ -s "$ART/vmlinux.zst" && -s "$ART/generated-output.tar.zst" ]] || fail 'missing #8 foundation files'
mkdir -p "$K/out"
tar --zstd -xf "$ART/generated-output.tar.zst" -C "$K/out"
zstd -q -d -f "$ART/vmlinux.zst" -o "$K/out/vmlinux"
python3 ci/stage18/verify_foundation.py

note '--- INSTALL VERIFIED ANDROID CLANG r510928 ---'
mkdir -p prebuilts/clang/host/linux-x86
git clone --depth=1 --filter=blob:none --sparse --branch android15-platform-release \
  https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 \
  prebuilts/clang/host/linux-x86 >ci-out/stage18-logs/clang_clone.log 2>&1
# Stable source revision recorded in successful stage17 foundation #8.
CLANG_SHA=921f6da692b1ffc96a0daa7e741373f0089d40b0
if [[ "$(git -C prebuilts/clang/host/linux-x86 rev-parse HEAD)" != "$CLANG_SHA" ]]; then
  git -C prebuilts/clang/host/linux-x86 fetch --depth=1 --filter=blob:none origin "$CLANG_SHA" \
    >>ci-out/stage18-logs/clang_clone.log 2>&1
  git -C prebuilts/clang/host/linux-x86 checkout --detach "$CLANG_SHA"
fi
git -C prebuilts/clang/host/linux-x86 sparse-checkout set clang-r510928
[[ "$(git -C prebuilts/clang/host/linux-x86 rev-parse HEAD)" == "$CLANG_SHA" ]] || fail 'Clang source revision mismatch'
export PATH="$GITHUB_WORKSPACE/prebuilts/clang/host/linux-x86/clang-r510928/bin:$PATH"
export LLVM=1 LLVM_IAS=1 ARCH=arm64 SUBARCH=arm64 CCACHE_DISABLE=1
clang --version | tee ci-out/stage18_clang.txt
ld.lld --version | tee ci-out/stage18_lld.txt
grep -q '11368308' ci-out/stage18_clang.txt || fail 'wrong clang Android build ID'
grep -q 'clang version 18.0.0' ci-out/stage18_clang.txt || fail 'wrong Clang version'
grep -q '477610d4' ci-out/stage18_clang.txt || fail 'wrong LLVM compiler revision'
grep -q 'LLD 18' ci-out/stage18_lld.txt || fail 'wrong LLD version'

note '--- REPRODUCE STAGE17 PAHOLE 1.27 BTF GENERATOR (INCLUDING SEGFAULT FIX) ---'
mkdir -p .ci-tools
git clone --depth=1 --branch v1.27 https://github.com/acmel/dwarves.git .ci-tools/dwarves \
  > ci-out/stage18-logs/dwarves_clone.log 2>&1
[[ "$(git -C .ci-tools/dwarves rev-parse HEAD)" == 3e265dac5ec85b956c664464072196c37d2af4f3 ]] || fail 'unexpected dwarves source revision'
python3 - <<'PY'
from pathlib import Path
p = Path('.ci-tools/dwarves/dwarves.c')
s = p.read_text()
old = '\t\tINIT_LIST_HEAD(&cu->tool_list);\n'
new = old + '\t\tINIT_LIST_HEAD(&cu->node);\n'
if s.count(old) != 1 or 'INIT_LIST_HEAD(&cu->node);' in s:
    raise SystemExit('BLOCKED: unexpected dwarves source, cannot safely apply patch')
p.write_text(s.replace(old, new, 1))
PY
cmake -S .ci-tools/dwarves -B .ci-tools/dwarves-build \
  -DCMAKE_BUILD_TYPE=Release -DLIBBPF_EMBEDDED=OFF -D__LIB=lib \
  -DCMAKE_INSTALL_PREFIX="$GITHUB_WORKSPACE/.ci-tools/dwarves-install" \
  > ci-out/stage18-logs/dwarves_cmake.log 2>&1
cmake --build .ci-tools/dwarves-build --parallel 2 \
  > ci-out/stage18-logs/dwarves_build.log 2>&1
cmake --install .ci-tools/dwarves-build > ci-out/stage18-logs/dwarves_install.log 2>&1
export PATH="$GITHUB_WORKSPACE/.ci-tools/dwarves-install/bin:$PATH"
export LD_LIBRARY_PATH="$GITHUB_WORKSPACE/.ci-tools/dwarves-install/lib:${LD_LIBRARY_PATH:-}"
pahole --version | tee ci-out/stage18_pahole.txt
grep -q 'v1.27' ci-out/stage18_pahole.txt || fail 'pahole version mismatch'

note '--- RESTORE MISSING KERNEL HOST SCRIPTS USING MATCHING SOURCE/CONFIG ---'
# The #8 archive contains .config, generated headers, modpost, fixdep, module.lds,
# but not every helper (e.g. scripts/genksyms). Generate these normally, rather than
# inventing them or copying build output from an unrelated kernel.
if make -C "$K" O=out ARCH=arm64 LLVM=1 CC='ccache clang' HOSTCC='ccache clang' \
  -j2 scripts modules_prepare >ci-out/stage18-logs/modules_prepare.log 2>&1; then
  note 'Kernel host scripts preparation successful'
else
  tail -n 90 ci-out/stage18-logs/modules_prepare.log || true
  fail 'matching kernel scripts/modules_prepare failed'
fi
python3 ci/stage18/verify_foundation.py

note '--- CHECK BUILD OUTPUT FREE DISK AND RESOURCES ---'
df -h . | tee ci-out/stage18_disk.txt
free -h | tee ci-out/stage18_memory.txt
if (( $(df -Pm . | awk 'NR==2 {print $4}') < 6000 )); then
  fail 'less than 6GiB free after foundation restore'
fi

if [[ "$MODE" == preflight ]]; then
  note 'STAGE18 PREFLIGHT PASS. No external .ko built. Select baseline only after reviewing diagnostics.'
  exit 0
fi

note '--- BUILD AUTHENTIC EXTERNAL SYMBOL PROVIDERS IN DEPENDENCY ORDER ---'
SYMS=()
LOG_DIR=ci-out/stage18-logs
RUN_ID=0
build_external() {
  local label="$1" rel="$2" make_flags="$3" kcflags="$4" rootarg="$5" expected_ko="$6"
  local dir="$MOD/$rel" log="$LOG_DIR/${label}.log" rc
  [[ -d "$dir" ]] || fail "missing provider source $rel"
  # A clean runner has no stale outputs; still enforce no pre-existing .ko/symvers.
  if find "$dir" -type f -name '*.ko' -print -quit | grep -q .; then
    fail "stale pre-existing compiled .ko in $rel"
  fi
  [[ ! -e "$dir/Module.symvers" ]] || fail "stale Module.symvers at $rel"
  local cmd=(make -C "$K" O=out ARCH=arm64 LLVM=1 CC='ccache clang' HOSTCC='ccache clang' \
             "M=$dir" -j"$J" modules)
  if [[ -n "$rootarg" ]]; then cmd+=("$rootarg"); fi
  if [[ -n "$kcflags" ]]; then cmd+=("KCFLAGS=$kcflags"); fi
  if [[ -n "$make_flags" ]]; then
    local vals=(); read -r -a vals <<< "$make_flags"
    cmd+=("${vals[@]}")
  fi
  if (( ${#SYMS[@]} > 0 )); then
    local symbols_string="${SYMS[*]}"
    cmd+=("KBUILD_EXTRA_SYMBOLS=$symbols_string")
  fi
  note "BUILD $label: $(printf '%q ' "${cmd[@]}")"
  if "${cmd[@]}" > "$log" 2>&1; then
    :
  else
    rc=$?
    tail -n 100 "$log" || true
    fail "$label make failed (rc=$rc), see $log"
  fi
  [[ -s "$dir/$expected_ko" ]] || {
    find "$dir" -name '*.ko' -print >>"$log" || true
    fail "$label: expected fresh $expected_ko not produced"
  }
  [[ -f "$dir/Module.symvers" ]] || fail "$label: genuine provider Module.symvers not generated"
  SYMS+=("$dir/Module.symvers")
  note "PROVIDER PASS: $label"
}

# Oplus: Kbuild selection flags are from japq7s build-oplus.sh, not inferred.
# cmdline_parser supplies runtime boot symbols to bootmode.
build_external oplus_cmdline 'oplus/kernel/boot/cmdline_parser' \
  'CONFIG_OPLUS_FEATURE_OPLUSBOOT=m CONFIG_OPLUS_FEATURE_FTMMODE=m CONFIG_OPLUS_FEATURE_CHARGERPRESENT=m CONFIG_OPLUS_FEATURE_BUILDVARIANT=m' \
  '-DCONFIG_OPLUS_SYSTEM_KERNEL_QCOM' '' 'oplusboot.ko'
build_external oplus_bootmode 'oplus/kernel/boot/bootmode' \
  'CONFIG_OPLUS_FEATURE_BOOTMODE=m' '-DCONFIG_OPLUS_SYSTEM_KERNEL_QCOM' '' 'boot_mode.ko'
build_external oplus_projectinfo 'oplus/kernel/boot/oplus_projectinfo' \
  'CONFIG_OPLUS_FEATURE_OPROJECT=m CONFIG_OPLUS_SYSTEM_KERNEL_QCOM=y OPLUS_VND_BUILD_CHIPSET_COMPANY=QCOM' \
  '-DCONFIG_OPLUS_SYSTEM_KERNEL_QCOM' '' 'oplus_bsp_boot_projectinfo.ko'
build_external oplus_device_info 'oplus/kernel/device_info/device_info' \
  'CONFIG_OPLUS_DEVICE_INFO=m' '-DCONFIG_OPLUS_SYSTEM_KERNEL_QCOM' '' 'device_info.ko'
build_external oplus_touchpanel_notify 'oplus/kernel/touchpanel/touchpanel_notify' \
  'CONFIG_TOUCHPANEL_NOTIFY=m' '-DCONFIG_OPLUS_SYSTEM_KERNEL_QCOM' '' 'oplus_bsp_tp_notify.ko'

# Qualcomm: author flags / root variables; projects may have additional
# dependencies, which must be reported, not hidden by KBUILD_MODPOST_WARN.
build_external qcom_securemsm 'qcom/opensource/securemsm-kernel' \
  'CONFIG_DISABLE_TEST_MODULES=y CONFIG_QCOM_SMCINVOKE=m CONFIG_QSEECOM=m CONFIG_QTI_TZ_LOG=m CONFIG_HDCP_QSEECOM=m CONFIG_CRYPTO_DEV_QCEDEV=m CONFIG_CRYPTO_DEV_QCRYPTO=m CONFIG_HW_RANDOM_MSM_LEGACY=m CONFIG_QTI_SMMU_PROXY=m' \
  '' "SSG_MODULE_ROOT=$Q/securemsm-kernel" 'hdcp_qseecom_dlkm.ko'
build_external qcom_ext_display 'qcom/opensource/mm-drivers/msm_ext_display' \
  '' '' "MSM_EXT_DISPLAY_ROOT=$Q/mm-drivers/" 'msm_ext_display.ko'
build_external qcom_mmrm 'qcom/opensource/mmrm-driver' \
  '' '' "MMRM_ROOT=$Q/mmrm-driver" 'driver/msm-mmrm.ko'

python3 ci/stage18/verify_external.py
note '--- BUILD PRISTINE DISPLAY ROOT, NOT msm/ SUBDIRECTORY ---'
DISPLAY_ROOT="$Q/display-drivers"
[[ -d "$DISPLAY_ROOT/msm/iris/iris5" ]] || fail 'missing Iris5 source'
if find "$DISPLAY_ROOT" -type f -name '*.ko' -print -quit | grep -q .; then
  fail 'stale Display .ko before baseline'
fi
[[ ! -e "$DISPLAY_ROOT/Module.symvers" ]] || fail 'stale Display Module.symvers'
DISPLAY_CMD=(make -C "$K" O=out ARCH=arm64 LLVM=1 CC='ccache clang' HOSTCC='ccache clang'
  "M=$DISPLAY_ROOT" "DISPLAY_ROOT=$DISPLAY_ROOT" CONFIG_DRM_MSM=m
  "KBUILD_EXTRA_SYMBOLS=${SYMS[*]}" -j"$J" modules)
note "BUILD original display: $(printf '%q ' "${DISPLAY_CMD[@]}")"
if "${DISPLAY_CMD[@]}" >"$LOG_DIR/display_pristine.log" 2>&1; then :
else
  rc=$?
  tail -n 130 "$LOG_DIR/display_pristine.log" || true
  fail "Display compile failure rc=$rc"
fi
DISPLAY_KO="$DISPLAY_ROOT/msm/msm_drm.ko"
[[ -s "$DISPLAY_KO" ]] || fail "Display build didn't produce $DISPLAY_KO"
python3 ci/stage18/verify_display.py "$DISPLAY_KO"
mkdir -p ci-out/baseline
cp "$DISPLAY_KO" ci-out/baseline/msm_drm.ko
if [[ -f "$DISPLAY_ROOT/Module.symvers" ]]; then
  cp "$DISPLAY_ROOT/Module.symvers" ci-out/baseline/Module.symvers
fi
sha256sum "$DISPLAY_KO" | tee ci-out/baseline/msm_drm.sha256
note 'STAGE18 UNMODIFIED DISPLAY BASELINE ABI PASSED. Offline-only; not safe to flash without separate review.'
