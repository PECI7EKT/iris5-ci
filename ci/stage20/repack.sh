#!/usr/bin/env bash
# OFFLINE candidate only. No flashing and no AVB/vbmeta changes.
set -euo pipefail
mkdir -p stage20-output
exec > >(tee stage20-output/build.log) 2>&1
MODE="${STAGE20_MODE:-audit}"
[[ "$MODE" == audit || "$MODE" == assemble ]] || { echo 'INVALID mode'; exit 2; }
set -x
# Pin BOTH the original source and rebuilt source to audited SHA256.
BASE_SHA=e2b9b423fbcf804e3f6fb4678441e1f0ddc7bee61fccab3d7c2da8e3c7c13237
BASE_FS_SHA=347c16203df84854de9733d1ac4f82cbb08eeae1b3e31bd0e34a81ffbd8365a8
MODULE_SHA=922a59ba3d24598b261a65cdb22043155045c7aeaf6e73d11dfe3031f96f4134
ORIG_MOD_SHA=d8cdfbd7ce0282f4372859d79f3e8ba18ef3b69999dc5246437debe9bbf452b1
SIZE=31768576
IN='source/senna-6.6.139-gki+-20261006-2201-ak3.zip'
KO='stage18/baseline/msm_drm.ko'
test -f "$IN" && test -f "$KO"
echo "$BASE_SHA  $IN" | sha256sum -c -
echo "$MODULE_SHA  $KO" | sha256sum -c -
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
  erofs-utils llvm python3 unzip
# Build pinned erofs-utils with SELinux xattr extraction support.
sudo apt-get install -y -qq --no-install-recommends \
  autoconf automake libtool pkg-config \
  liblz4-dev liblzma-dev libzstd-dev uuid-dev zlib1g-dev

mkdir -p .ci-tools
git clone --depth=1 --branch v1.8.10 \
  https://github.com/erofs/erofs-utils.git \
  .ci-tools/erofs-utils

EXPECTED_EROFS_SHA=51b5939b5f783221310d25146e6a2019ba8129b6
ACTUAL_EROFS_SHA=$(git -C .ci-tools/erofs-utils rev-parse HEAD)

[[ "$ACTUAL_EROFS_SHA" == "$EXPECTED_EROFS_SHA" ]] || {
  echo "BLOCKED: erofs-utils commit mismatch"
  exit 3
}

(
  cd .ci-tools/erofs-utils
  ./autogen.sh
  ./configure --prefix=/usr/local \
    --enable-lz4 --enable-lzma \
    --with-libzstd --with-uuid --disable-fuse
  make -j2
  sudo make install
)

sudo ldconfig

# Require the newer fsck.erofs, including when invoked via sudo.
sudo fsck.erofs --help | grep -Fq -- '--[no-]xattrs' || {
  echo "BLOCKED: fsck.erofs does not support xattrs"
  exit 3
}

echo "EROFS XATTR SUPPORT: PASS"
mkdir -p work/original work/rebuilt
unzip -p "$IN" vendor_dlkm.img > work/original.img
echo "$BASE_FS_SHA  work/original.img" | sha256sum -c -
[[ "$(wc -c <work/original.img)" == "$SIZE" ]]
# Verify existing filesystem before any modifications.
fsck.erofs work/original.img
# Filesystem metadata must include original per-file SELinux labels.
sudo fsck.erofs --xattrs --extract=work/original work/original.img
ORIGINAL=work/original/lib/modules/msm_drm.ko
test -f "$ORIGINAL"
echo "$ORIG_MOD_SHA  $ORIGINAL" | sha256sum -c -
# Keep original metadata and xattrs in-place: overwrite bytes of existing regular file.
# Never use cp/install/mv on this path, which may replace its inode attributes.
python3 ci/stage20/manifest.py work/original stage20-output/original_manifest.json
sudo python3 - <<'PY'
import os
p='work/original/lib/modules/msm_drm.ko'
assert 'security.selinux' in os.listxattr(p), 'BLOCKED: source file SELinux xattr absent after extract'
print('Original msm_drm SELinux:',os.getxattr(p,'security.selinux'))
PY
llvm-objcopy --strip-debug "$KO" work/stripped.ko
python3 - <<'PY'
import pathlib,subprocess,hashlib
before=pathlib.Path('stage18/baseline/msm_drm.ko')
after=pathlib.Path('work/stripped.ko')
assert after.stat().st_size < 10_000_000, 'BLOCKED: debug sections not removed'
def dump(p):
    txt=subprocess.check_output(['readelf','-SW',str(p)],text=True)
    return txt
for sec in ['.BTF','__versions','.modinfo','.symtab']:
    assert sec in dump(before) and sec in dump(after), f'BLOCKED missing section {sec}'
# Strict reference comparison of retained sections via llvm-readelf hex dumps.
for sec in ['.BTF','__versions','.modinfo']:
    def hexd(p):
        return subprocess.check_output(['readelf','-x',sec,str(p)],text=True).splitlines()[2:]
    if hexd(before)!=hexd(after):
        raise SystemExit('BLOCKED: stripped section differs: '+sec)
print('STRIP AUDIT PASS: BTF, modversions and modinfo unchanged')
PY
sha256sum work/stripped.ko > stage20-output/stripped_module.sha256
cp work/stripped.ko stage20-output/STAGE18-unmodified-stripped-msm_drm.ko
if [[ "$MODE" == audit ]]; then
  echo 'AUDIT PASS: no reconstructed EROFS image generated'
  exit 0
fi
sudo sh -c 'cat work/stripped.ko >work/original/lib/modules/msm_drm.ko'
# Rebuild a self-contained image using LZ4HC, preserving inode ownership/modes/xattrs.
sudo mkfs.erofs -z lz4hc,12 -b 4096 -U 3fc68086-128a-7845-99d2-09bfefc47c90 \
  work/rebuilt.img work/original
BYTES=$(wc -c <work/rebuilt.img)
if (( BYTES > SIZE )); then
 echo "BLOCKED: rebuilt EROFS is $BYTES > partition $SIZE bytes"
 exit 5
fi
sudo truncate -s "$SIZE" work/rebuilt.img
fsck.erofs work/rebuilt.img
sudo fsck.erofs --xattrs --extract=work/rebuilt work/rebuilt.img
python3 ci/stage20/manifest.py work/rebuilt stage20-output/rebuilt_manifest.json stage20-output/original_manifest.json
cmp work/rebuilt/lib/modules/msm_drm.ko work/stripped.ko
echo 'IMAGE MANIFEST, SIZE, BTF, CHECKSUM AND EXTRACTION PASSED (NOT RUNTIME TESTED)'
cp work/rebuilt.img stage20-output/candidate_VENDOR_DLKM_B_OFFLINE_ONLY.img
sha256sum stage20-output/candidate_VENDOR_DLKM_B_OFFLINE_ONLY.img >stage20-output/candidate.sha256
