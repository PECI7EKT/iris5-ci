#!/usr/bin/env bash
# Filesystem-only packaging. Never contacts a phone, writes a block device,
# changes AVB policy, or rebuilds kernel/driver sources.
set -euo pipefail
OUT="$GITHUB_WORKSPACE/stage50b-image-output"
W="$GITHUB_WORKSPACE/stage50b-image-work"
SCRIPT="$GITHUB_WORKSPACE/ci/stage50b_image"
mkdir -p "$OUT"/{logs,audit,modules} "$W"
exec > >(tee "$OUT/logs/build.log") 2>&1
trap 'rc=$?; printf "%s\n" "$rc" > "$OUT/exit_code.txt"' EXIT
BASE="$GITHUB_WORKSPACE/input44/STAGE44-HOST-DIAG_VENDOR_DLKM_B.img"
REF="$GITHUB_WORKSPACE/input50b/modules/STAGE44_BASELINE_msm_drm.ko"
NEW="$GITHUB_WORKSPACE/input50b/modules/STAGE50B_OBSERVE_msm_drm.ko"
echo "9d792502d218f5a6ef1e336ebb77822ac30a5191c282f09782b5c823fe345023  $BASE" | sha256sum -c -
echo "f1239ce975972d43390a8a377eed6ddee59d3022f8b60223eaed51f45019947b  $REF" | sha256sum -c -
echo "367e411e7e57a803a361d36c6615ce1f2a92855a2561b5ca2260ff2584eca1d9  $NEW" | sha256sum -c -
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  autoconf automake libtool pkg-config liblz4-dev liblzma-dev libzstd-dev \
  uuid-dev zlib1g-dev llvm-18 python3-pyelftools
git clone --depth=1 --branch v1.8.10 https://github.com/erofs/erofs-utils.git "$W/erofs-utils" > "$OUT/logs/erofs_clone.log" 2>&1
[[ "$(git -C "$W/erofs-utils" rev-parse HEAD)" == 51b5939b5f783221310d25146e6a2019ba8129b6 ]]
(
 cd "$W/erofs-utils"
 ./autogen.sh
 ./configure --prefix="$W/tools" --enable-lz4 --enable-lzma --with-libzstd --with-uuid --disable-fuse
 make -j2
 make install
) > "$OUT/logs/erofs_tools_build.log" 2>&1
MKFS="$W/tools/bin/mkfs.erofs"
FSCK="$W/tools/bin/fsck.erofs"
DUMP="$W/tools/bin/dump.erofs"
"$MKFS" -V > "$OUT/audit/mkfs_version.txt"
"$FSCK" -V > "$OUT/audit/fsck_version.txt"
llvm-objcopy-18 --version > "$OUT/audit/objcopy_version.txt"
sha256sum "$MKFS" "$FSCK" "$DUMP" "$(command -v llvm-objcopy-18)" > "$OUT/audit/tools.sha256"
"$FSCK" "$BASE" > "$OUT/logs/source_fsck.log" 2>&1
"$DUMP" -s "$BASE" > "$OUT/audit/source_superblock.txt"
python3 "$SCRIPT/erofs_metadata.py" "$BASE" "$OUT/audit/source_raw.json"
sudo "$FSCK" --xattrs --extract="$W/original" "$BASE" > "$OUT/logs/source_extract.log" 2>&1
sudo python3 "$SCRIPT/tree_audit.py" restore "$OUT/audit/source_raw.json" "$W/original"
python3 "$SCRIPT/erofs_metadata.py" "$BASE" "$OUT/audit/source_raw.json" "$W/original"
llvm-objcopy-18 --strip-debug "$REF" "$W/reference_stripped.ko"
echo "42eba4ef4ed0c0956c512aa5bf9fe8727a3c0f892a2415d5e19ffea595119a12  $W/reference_stripped.ko" | sha256sum -c -
cmp "$W/original/lib/modules/msm_drm.ko" "$W/reference_stripped.ko"
llvm-objcopy-18 --strip-debug "$NEW" "$OUT/modules/STAGE50B-OBSERVE-stripped-msm_drm.ko"
python3 "$SCRIPT/module_audit.py" "$NEW" "$OUT/modules/STAGE50B-OBSERVE-stripped-msm_drm.ko" "$OUT/audit/module_strip_audit.json"
sudo python3 "$SCRIPT/tree_audit.py" replace "$OUT/audit/source_raw.json" "$W/original" "$OUT/modules/STAGE50B-OBSERVE-stripped-msm_drm.ko"
# Source Stage44 profile inherited from pinned Stage36 recipe: legacy LZ4hc12,
# 4096-byte blocks and clusters, original UUID. Preserve every file timestamp.
CMD=("$MKFS" -z lz4hc,12 -b 4096 -C 4096 -U 3fc68086-128a-7845-99d2-09bfefc47c90
     -T 1792515951 --mkfs-time --preserve-mtime "$W/candidate.img" "$W/original")
printf '%q ' "${CMD[@]}" > "$OUT/audit/mkfs_command.txt"
printf '\n' >> "$OUT/audit/mkfs_command.txt"
sudo "${CMD[@]}" > "$OUT/logs/mkfs.log" 2>&1
SIZE=$(stat -c %s "$W/candidate.img")
if (( SIZE > 31768576 )); then
 echo "BLOCKED: EROFS size $SIZE exceeds verified user-confirmed Stage44 image size 31768576"; exit 5
fi
sudo truncate -s 31768576 "$W/candidate.img"
"$FSCK" "$W/candidate.img" > "$OUT/logs/candidate_fsck.log" 2>&1
"$DUMP" -s "$W/candidate.img" > "$OUT/audit/candidate_superblock.txt"
sudo "$FSCK" --xattrs --extract="$W/reextracted" "$W/candidate.img" > "$OUT/logs/candidate_extract.log" 2>&1
python3 "$SCRIPT/erofs_metadata.py" "$W/candidate.img" "$OUT/audit/candidate_raw.json" "$W/reextracted"
sudo python3 "$SCRIPT/tree_audit.py" compare "$OUT/audit/source_raw.json" "$OUT/audit/candidate_raw.json" "$W/reextracted" "$OUT/audit/filesystem_comparison.json" "$OUT/modules/STAGE50B-OBSERVE-stripped-msm_drm.ko"
cmp "$W/reextracted/lib/modules/msm_drm.ko" "$OUT/modules/STAGE50B-OBSERVE-stripped-msm_drm.ko"
# Only this point exports a target image. Failed candidates stay in ephemeral W.
cp "$W/candidate.img" "$OUT/STAGE50B-OBSERVE_VENDOR_DLKM_B.img"
sha256sum "$OUT/STAGE50B-OBSERVE_VENDOR_DLKM_B.img" "$OUT/modules/"*.ko > "$OUT/SHA256SUMS"
echo 'PASS: Stage50B EROFS validated against exact user-confirmed Stage44; no phone operations'
