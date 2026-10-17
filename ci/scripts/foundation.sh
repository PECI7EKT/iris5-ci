#!/usr/bin/env bash
# EXPERIMENTAL. Builds only the kernel foundation, not external Display or phone images.
set -euo pipefail
mkdir -p ci-out
{
 echo '--- RUNNER ---'; uname -a; free -h; df -h .;
 echo '--- FREE DISK (GiB) ---'; df -BG --output=avail . | tail -1
} | tee ci-out/runner_resources.txt

avail_mb="$(df -Pm --output=avail . | tail -1 | tr -d ' ')"
ram_kb="$(awk '/MemTotal:/ { print $2 }' /proc/meminfo)"
if (( avail_mb < 11000 )); then
 echo "BLOCKED: only ${avail_mb} MiB available; require at least 11000 MiB to start heavy checkout." | tee ci-out/blocker.txt
 exit 2
fi
if (( ram_kb < 11500000 )); then
 echo "BLOCKED: ~${ram_kb} KiB RAM. Full ThinLTO+BTF needs a larger runner." | tee ci-out/blocker.txt
 exit 2
fi

echo '--- INSTALL BUILD TOOLS ---'
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  build-essential bc bison flex ccache libelf-dev libssl-dev \
  dwarves zstd lz4 cpio rsync python3-pyelftools

echo '--- CHECKOUT PINNED KERNEL ---'
git -C sources/kernel checkout --detach 45174e44b18f5d9024b3024e3de0d48c610b2bb3

echo '--- PIN AN OFFICIAL ANDROID RELEASE BRANCH / RECORD ITS ACTUAL SHA ---'
mkdir -p prebuilts/clang/host/linux-x86
git clone --depth=1 --filter=blob:none --sparse --branch android15-platform-release \
  https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 \
  prebuilts/clang/host/linux-x86
# NOTE: branch can advance; version/revision SHA is recorded below, and
# the compiler fingerprint must match before building. Exact binary pin remains a gate.
git -C prebuilts/clang/host/linux-x86 sparse-checkout set clang-r510928
git -C prebuilts/clang/host/linux-x86 rev-parse HEAD | tee ci-out/clang_git_commit.txt
export PATH="${GITHUB_WORKSPACE}/prebuilts/clang/host/linux-x86/clang-r510928/bin:${PATH}"
export LLVM=1 LLVM_IAS=1 CCACHE_DISABLE=1
clang --version | tee ci-out/clang_version.txt
ld.lld --version | tee ci-out/lld_version.txt
pahole --version | tee ci-out/pahole_version.txt
# A name 'r510928' alone is insufficient.
grep -q '11368308' ci-out/clang_version.txt || { echo 'BLOCKED: Android compiler package is not 11368308'; exit 3; }
grep -q 'clang version 18.0.0' ci-out/clang_version.txt || { echo 'BLOCKED: wrong Clang version'; exit 3; }
grep -q '477610d4' ci-out/clang_version.txt || { echo 'BLOCKED: wrong LLVM revision'; exit 3; }
grep -q 'LLD 18' ci-out/lld_version.txt || { echo 'BLOCKED: wrong LLD version'; exit 3; }
# The original kernel was made with pahole 1.27, so fail rather than silently change BTF.
grep -Eq '(^|[^0-9])1\.27([^0-9]|$)' ci-out/pahole_version.txt || { echo 'BLOCKED: pahole 1.27 needed'; exit 3; }

echo '--- PREPARE CONFIG (DO NOT REPLACE WITH RANDOM GENERATED CONFIG) ---'
make -C sources/kernel O=out ARCH=arm64 LLVM=1 CC='ccache clang' HOSTCC='ccache clang' \
  -j2 gki_defconfig vendor/waipio_perf.config 2>&1 | tee ci-out/config.log
sha256sum sources/kernel/out/.config | tee ci-out/generated_config_sha256.txt
cmp -s sources/kernel/out/.config ci/reference/original_Image.config || {
 echo 'BLOCKED: generated kernel .config differs from original Image IKCONFIG. Review the diff before a build.'
 diff -u ci/reference/original_Image.config sources/kernel/out/.config > ci-out/config_diff.txt || true
 exit 3
}

echo '--- COMPILE FOUNDATION (Image + in-tree modules) ---'
make -C sources/kernel O=out ARCH=arm64 LLVM=1 CC='ccache clang' HOSTCC='ccache clang' \
  -j2 Image modules 2>&1 | tee ci-out/kernel_make.log
for f in sources/kernel/out/{vmlinux,Module.symvers,include/config/auto.conf,include/generated/autoconf.h}; do
 test -s "$f" || { echo "Missing required build output: $f"; exit 4; }
done
readelf -SW sources/kernel/out/vmlinux | grep -q '\.BTF' || { echo 'Missing vmlinux BTF'; exit 4; }
python3 ci/verify_new_symvers.py sources/kernel/out/Module.symvers
cp sources/kernel/out/Module.symvers ci-out/generated_kernel_Module.symvers
cp sources/kernel/out/.config ci-out/generated_kernel.config
printf 'FOUNDATION BUILD SUCCESS (no external module built)\n' | tee ci-out/foundation_status.txt
