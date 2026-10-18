#!/usr/bin/env bash
# Stage 17 v2. No phone operations, external display module, signing or image packaging.
set -euo pipefail
mode="${1:-toolchain}"
case "$mode" in toolchain|foundation) ;; *) echo "Unsupported mode: $mode" >&2; exit 2;; esac
mkdir -p ci-out
# Preserve facts even if a later step exits early.
on_exit() {
  local status=$?
  { printf '\n--- FINAL STATUS %s ---\n' "$status"; date -u; df -h .; free -h; } >> ci-out/resource_history.txt 2>&1 || true
  printf '%s\n' "$status" > ci-out/exit_status.txt
}
trap on_exit EXIT
{
  echo "mode=$mode"; date -u; uname -a; df -h .; free -h;
  echo '--- CPU ---'; nproc;
} | tee ci-out/resource_history.txt

avail_mb="$(df -Pm . | awk 'NR==2 {print $4}')"
ram_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
if (( avail_mb < 9500 || ram_kb < 11500000 )); then
  printf 'BLOCKED: need >=9500MiB free disk and >=11500000KiB RAM; disk=%sMiB RAM=%sKiB\n' "$avail_mb" "$ram_kb" | tee ci-out/blocker.txt
  exit 2
fi

# This build only needs Linux host tools; apt dwarves (Ubuntu 24.04) is older than v1.27.
echo '--- INSTALL BASIC BUILD TOOLS ---'
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  build-essential bc bison flex ccache cmake pkg-config libbpf-dev libdw-dev \
  libelf-dev libssl-dev zlib1g-dev zstd lz4 cpio rsync python3-pyelftools \
  binutils git ca-certificates gcc-aarch64-linux-gnu libc6-dev-arm64-cross

echo '--- BUILD PINNED PAHOLE 1.27 ---'
mkdir -p .ci-tools
# Verified GitHub tag v1.27 resolves to this commit (not moving HEAD).
DWARVES_COMMIT=3e265dac5ec85b956c664464072196c37d2af4f3
git clone --depth=1 --branch v1.27 https://github.com/acmel/dwarves.git .ci-tools/dwarves
actual="$(git -C .ci-tools/dwarves rev-parse HEAD)"
printf '%s\n' "$actual" | tee ci-out/dwarves_commit.txt
[[ "$actual" == "$DWARVES_COMMIT" ]] || { echo "BLOCKED: unexpected dwarves commit" | tee ci-out/blocker.txt; exit 3; }
cmake -S .ci-tools/dwarves -B .ci-tools/dwarves-build \
  -DCMAKE_BUILD_TYPE=Release -DLIBBPF_EMBEDDED=OFF -D__LIB=lib \
  -DCMAKE_INSTALL_PREFIX="$GITHUB_WORKSPACE/.ci-tools/dwarves-install" \
  2>&1 | tee ci-out/dwarves_cmake.log
cmake --build .ci-tools/dwarves-build --parallel 2 2>&1 | tee ci-out/dwarves_build.log
cmake --install .ci-tools/dwarves-build 2>&1 | tee ci-out/dwarves_install.log
export PATH="$GITHUB_WORKSPACE/.ci-tools/dwarves-install/bin:$PATH"
export LD_LIBRARY_PATH="$GITHUB_WORKSPACE/.ci-tools/dwarves-install/lib:${LD_LIBRARY_PATH:-}"
command -v pahole | tee ci-out/pahole_path.txt
pahole --version | tee ci-out/pahole_version.txt
grep -Eq '(^|[^0-9])1\.27([^0-9]|$)' ci-out/pahole_version.txt || {
  echo 'BLOCKED: pahole is not 1.27' | tee ci-out/blocker.txt; exit 3;
}

echo '--- PINNED KERNEL TREE ---'
git -C sources/kernel checkout --detach 45174e44b18f5d9024b3024e3de0d48c610b2bb3 \
  2>&1 | tee ci-out/kernel_checkout.log

echo '--- DOWNLOAD AND VERIFY ANDROID CLANG ---'
mkdir -p prebuilts/clang/host/linux-x86
git clone --depth=1 --filter=blob:none --sparse --branch android15-platform-release \
  https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 \
  prebuilts/clang/host/linux-x86 2>&1 | tee ci-out/clang_clone.log
git -C prebuilts/clang/host/linux-x86 sparse-checkout set clang-r510928 \
  2>&1 | tee ci-out/clang_sparse.log
git -C prebuilts/clang/host/linux-x86 rev-parse HEAD | tee ci-out/clang_git_commit.txt
export PATH="$GITHUB_WORKSPACE/prebuilts/clang/host/linux-x86/clang-r510928/bin:$PATH"
export LLVM=1 LLVM_IAS=1 CCACHE_DISABLE=1
clang --version | tee ci-out/clang_version.txt
ld.lld --version | tee ci-out/lld_version.txt
# Compare all available fingerprints against original image, not directory name alone.
grep -q '11368308' ci-out/clang_version.txt || { echo 'BLOCKED: Clang package ID mismatch' | tee ci-out/blocker.txt; exit 3; }
grep -q 'clang version 18.0.0' ci-out/clang_version.txt || { echo 'BLOCKED: Clang major version mismatch' | tee ci-out/blocker.txt; exit 3; }
grep -q '477610d4' ci-out/clang_version.txt || { echo 'BLOCKED: Clang revision mismatch' | tee ci-out/blocker.txt; exit 3; }
grep -q 'LLD 18' ci-out/lld_version.txt || { echo 'BLOCKED: LLD version mismatch' | tee ci-out/blocker.txt; exit 3; }
{
  echo '--- AFTER TOOLCHAIN / SOURCE CHECKOUT ---'; df -h .; free -h;
} | tee -a ci-out/resource_history.txt

echo '--- GENERATE KERNEL CONFIG AND COMPARE TO ORIGINAL IKCONFIG ---'
make -C sources/kernel O=out ARCH=arm64 LLVM=1 CC='ccache clang' HOSTCC='ccache clang' \
  -j2 gki_defconfig vendor/waipio_perf.config 2>&1 | tee ci-out/config.log
sha256sum sources/kernel/out/.config | tee ci-out/generated_config_sha256.txt
# Preserve the complete difference for review.
diff -u ci/reference/original_Image.config \
  sources/kernel/out/.config > ci-out/config_diff.txt || true

# Permit only the two independently reviewed host-dependent flags.
if ! diff -u ci/reference/original_Image.config \
  <(sed '/^CONFIG_CC_CAN_LINK=y$/d; /^CONFIG_UAPI_HEADER_TEST=y$/d' sources/kernel/out/.config) \
  > ci-out/config_unexpected_diff.txt; then
  echo 'BLOCKED: unexpected kernel config differences' | tee ci-out/blocker.txt
  exit 3
fi

echo 'CONFIG REVIEW PASS: no differences beyond two reviewed host-dependent flags' \
  | tee ci-out/config_status.txt
if [[ "$mode" == toolchain ]]; then
  echo 'TOOLCHAIN AND CONFIG GATES PASSED (no kernel build requested)' | tee ci-out/toolchain_status.txt
  exit 0
fi

avail_mb="$(df -Pm . | awk 'NR==2 {print $4}')"
if (( avail_mb < 6000 )); then
  echo "BLOCKED: only ${avail_mb}MiB free after checkout; do not start ThinLTO build" | tee ci-out/blocker.txt
  exit 2
fi

echo '--- COMPILE ONLY KERNEL IMAGE + IN-TREE MODULES ---'
make -C sources/kernel O=out ARCH=arm64 LLVM=1 CC='ccache clang' HOSTCC='ccache clang' \
  -j2 Image modules 2>&1 | tee ci-out/kernel_make.log
for f in sources/kernel/out/{vmlinux,Module.symvers,include/config/auto.conf,include/generated/autoconf.h}; do
  test -s "$f" || { echo "BLOCKED: missing $f" | tee ci-out/blocker.txt; exit 4; }
done
readelf -SW sources/kernel/out/vmlinux | grep -q '\.BTF' || {
  echo 'BLOCKED: vmlinux has no BTF' | tee ci-out/blocker.txt; exit 4;
}
python3 ci/verify_new_symvers.py sources/kernel/out/Module.symvers | tee ci-out/generated_crc_check.txt
cp sources/kernel/out/Module.symvers ci-out/generated_kernel_Module.symvers
cp sources/kernel/out/.config ci-out/generated_kernel.config
printf 'FOUNDATION BUILD SUCCESS, 739/739 reference kernel CRC match. NOT a Display build.\n' | tee ci-out/foundation_status.txt
