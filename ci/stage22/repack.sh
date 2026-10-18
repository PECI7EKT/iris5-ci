#!/usr/bin/env bash
# Stage22 isolated I1+SSC repack, using Stage20 EROFS/SELinux audit.
# Does NOT modify the original AK3, boot, vbmeta or phone.
set -euo pipefail
MODE="${STAGE22_IMAGE_MODE:-audit}"
[[ "$MODE" == audit || "$MODE" == assemble ]] || { echo 'BLOCKED: invalid mode'; exit 2; }
mkdir -p stage22-image-output
BASE='ci/stage20/repack.sh'
I1='stage22-source/modules/Stage22_I1_plus_SSC_msm_drm.ko'
PATCH='stage22-source/diffs/I1_plus_SSC.diff'

# The seven-variant artifact is the exact successful Stage19 run #3.
# This path and SHA pin the isolated I1 binary; I1 plus stock SSC policy only.
I1_SHA='a70fc3637b4cf9577584a34c6c801a92e3af0bc210810f8c194f2bd17ed3956f'
I1_PATCH_SHA='9c200c33361bbfc6bfcc63f05430ac8b7178fcc3f42951fcba9ce3a301f07e66'
I1_STRIPPED_SHA='d479bed161e8b91865f86974d9ee57ec372d9104ab6ac6becbd62ee0928bb822'
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
     'MODULE_SHA=a70fc3637b4cf9577584a34c6c801a92e3af0bc210810f8c194f2bd17ed3956f'),
    ("KO='stage18/baseline/msm_drm.ko'",
     "KO='stage22-source/modules/Stage22_I1_plus_SSC_msm_drm.ko'"),
    ("before=pathlib.Path('stage18/baseline/msm_drm.ko')",
     "before=pathlib.Path('stage22-source/modules/Stage22_I1_plus_SSC_msm_drm.ko')"),
    ('STAGE18-unmodified-stripped-msm_drm.ko',
     'STAGE22-I1-SSC-stripped-msm_drm.ko'),
    ('candidate_VENDOR_DLKM_B_OFFLINE_ONLY.img',
     'STAGE22-I1-SSC_VENDOR_DLKM_B_OFFLINE_ONLY.img'),
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
s=s.replace('stage20-output','stage22-image-output')
Path('ci/stage22/generated_repack.sh').write_text(s)
print('STAGE22 REPACK DIFF: only pin, module, labels and output directory changed')
PY

cat >stage22-image-output/provenance.txt <<EOF
Stage22 variant=I1 plus stock Oplus SSC policy
source_stage22_run=39171112531
source_stage22_artifact=iris5-stage22-build-2
stage22_I1_SSC_sha256=$I1_SHA
stage22_diff_sha256=$I1_PATCH_SHA
expected_stripped_I1_SSC_sha256=$I1_STRIPPED_SHA
AK3_release_tag=stage20-input
stage20_source_module=known-good control; installed and loaded on target
mode=$MODE
NOT FLASH APPROVAL
EOF

# Stage20 will re-verify the complete original AK3 image, 303 file entries,
# module metadata, EROFS extraction, xattrs, inode owner/mode, and output size.
STAGE20_MODE="$MODE" bash ci/stage22/generated_repack.sh

# Independently bind the newly stripped ELF to the exact audited Stage19 I1.
test -s stage22-image-output/STAGE22-I1-SSC-stripped-msm_drm.ko
echo "$I1_STRIPPED_SHA  stage22-image-output/STAGE22-I1-SSC-stripped-msm_drm.ko" | sha256sum -c -
if [[ "$MODE" == assemble ]]; then
  test -s stage22-image-output/STAGE22-I1-SSC_VENDOR_DLKM_B_OFFLINE_ONLY.img
  [[ "$(wc -c < stage22-image-output/STAGE22-I1-SSC_VENDOR_DLKM_B_OFFLINE_ONLY.img)" == '31768576' ]] || {
    echo 'BLOCKED: output partition size mismatch'; exit 5;
  }
  echo 'STAGE22 I1+SSC ASSEMBLE PASS: output hash and EROFS manifest checked; NOT RUNTIME TESTED'
else
  echo 'STAGE22 I1+SSC AUDIT PASS: no EROFS candidate image produced'
fi
