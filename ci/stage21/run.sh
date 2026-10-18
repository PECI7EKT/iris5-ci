#!/usr/bin/env bash
# Stage21 isolated I1-only repack, using Stage20 EROFS/SELinux audit.
# Does NOT modify the original AK3, boot, vbmeta or phone.
set -euo pipefail
MODE="${STAGE21_MODE:-audit}"
[[ "$MODE" == audit || "$MODE" == assemble ]] || { echo 'BLOCKED: invalid mode'; exit 2; }
mkdir -p stage21-output
BASE='ci/stage20/repack.sh'
I1='stage19/stage19/modules/I1_msm_drm.ko'
PATCH='ci/stage19/patches/0001-I1-require-complete-i2c-reads.patch'

# The seven-variant artifact is the exact successful Stage19 run #3.
# This path and SHA pin the isolated I1 binary; NO full-combo or D1 module.
I1_SHA='cecd6506a059a73673b41ff9997844290f361e730d53f0321eaf890f89b3c4c3'
I1_PATCH_SHA='d4a4b0f2a5c796ad642f3c61751b685474dd48750ce740061ce718ed4fcc223b'
I1_STRIPPED_SHA='01ceed78d74d89db40793c86bf5c233dde879ad26af6e6f34b9f3ab815c48728'
[[ -s "$I1" && -s "$PATCH" && -s "$BASE" ]] || { echo 'BLOCKED: missing pinned source'; exit 3; }
echo "$I1_SHA  $I1" | sha256sum -c -
echo "$I1_PATCH_SHA  $PATCH" | sha256sum -c -

# Generate a temporary Stage20 repacker with ONLY the module/paths changed.
# Count each expected source replacement, so upstream drift fails closed.
python3 - <<'PY'
from pathlib import Path
p=Path('ci/stage20/repack.sh')
s=p.read_text()
expected=[
    ('MODULE_SHA=922a59ba3d24598b261a65cdb22043155045c7aeaf6e73d11dfe3031f96f4134',
     'MODULE_SHA=cecd6506a059a73673b41ff9997844290f361e730d53f0321eaf890f89b3c4c3'),
    ("KO='stage18/baseline/msm_drm.ko'",
     "KO='stage19/stage19/modules/I1_msm_drm.ko'"),
    ("before=pathlib.Path('stage18/baseline/msm_drm.ko')",
     "before=pathlib.Path('stage19/stage19/modules/I1_msm_drm.ko')"),
    ('STAGE18-unmodified-stripped-msm_drm.ko',
     'STAGE21-I1-stripped-msm_drm.ko'),
    ('candidate_VENDOR_DLKM_B_OFFLINE_ONLY.img',
     'STAGE21-I1_VENDOR_DLKM_B_OFFLINE_ONLY.img'),
]
for src,dst in expected:
    expected_count = 2 if src == 'candidate_VENDOR_DLKM_B_OFFLINE_ONLY.img' else 1
    if s.count(src)!=expected_count:
        raise SystemExit(f'BLOCKED Stage20 script drift: expected {expected_count} occurrences of {src}')
    s=s.replace(src,dst)
if 'sudo truncate -s "$SIZE" work/rebuilt.img' not in s:
    raise SystemExit('BLOCKED: Stage20 root-owned image sizing fix missing')
if 'EXPECTED_EROFS_SHA=51b5939b5f783221310d25146e6a2019ba8129b6' not in s:
    raise SystemExit('BLOCKED: Stage20 pinned erofs-utils 1.8.10 fix missing')
if 'sudo fsck.erofs --xattrs --extract=work/rebuilt work/rebuilt.img' not in s:
    raise SystemExit('BLOCKED: strict SELinux xattr validation missing')
if 'sudo fsck.erofs --xattrs --extract=work/original work/original.img' not in s:
    raise SystemExit('BLOCKED: strict original xattr validation missing')
# Ensure that all diagnostics/artifacts cannot be confused with baseline Stage20.
s=s.replace('stage20-output','stage21-output')
Path('ci/stage21/generated_repack.sh').write_text(s)
print('STAGE21 REPACK DIFF: only pin, module, labels and output directory changed')
PY

cat >stage21-output/provenance.txt <<EOF
Stage21 variant=I1 ONLY
source_stage19_run=39125874244
source_stage19_artifact=iris5-stage19-build-3
stage19_I1_sha256=$I1_SHA
stage19_I1_patch_sha256=$I1_PATCH_SHA
expected_stripped_I1_sha256=$I1_STRIPPED_SHA
AK3_release_tag=stage20-input
stage20_source_module=known-good control; installed and loaded on target
mode=$MODE
NOT FLASH APPROVAL
EOF

# Stage20 will re-verify the complete original AK3 image, 303 file entries,
# module metadata, EROFS extraction, xattrs, inode owner/mode, and output size.
STAGE20_MODE="$MODE" bash ci/stage21/generated_repack.sh

# Independently bind the newly stripped ELF to the exact audited Stage19 I1.
test -s stage21-output/STAGE21-I1-stripped-msm_drm.ko
echo "$I1_STRIPPED_SHA  stage21-output/STAGE21-I1-stripped-msm_drm.ko" | sha256sum -c -
if [[ "$MODE" == assemble ]]; then
  test -s stage21-output/STAGE21-I1_VENDOR_DLKM_B_OFFLINE_ONLY.img
  [[ "$(wc -c < stage21-output/STAGE21-I1_VENDOR_DLKM_B_OFFLINE_ONLY.img)" == '31768576' ]] || {
    echo 'BLOCKED: output partition size mismatch'; exit 5;
  }
  echo 'STAGE21 I1 ASSEMBLE PASS: output hash and EROFS manifest checked; NOT RUNTIME TESTED'
else
  echo 'STAGE21 I1 AUDIT PASS: no EROFS candidate image produced'
fi
