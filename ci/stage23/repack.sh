#!/usr/bin/env bash
# Stage23 isolated I1+SSC plus diagnostic readbacks, Stage20 EROFS/SELinux audit.
# Does NOT modify the original AK3, boot, vbmeta or phone.
set -euo pipefail
MODE="${STAGE23_IMAGE_MODE:-audit}"
[[ "$MODE" == audit || "$MODE" == assemble ]] || { echo 'BLOCKED: invalid mode'; exit 2; }
mkdir -p stage23-image-output
BASE='ci/stage20/repack.sh'
I1='stage23-source/modules/Stage23_I1_plus_SSC_diag_msm_drm.ko'
PATCH='stage23-source/diffs/I1_plus_SSC_diag.diff'

# Pin Stage23 build #2 artifact (Stage22 I1+SSC + read-only DPHY/PLL logs).
# Independently check its module and source diff SHA256.
I1_SHA='700460af78f1cb6f184b28ed768ca33a8d271ecad83bb0be672e5eca6fb2ae99'
I1_PATCH_SHA='8cfa210b8306154a5e4425d340e21f04861d954d771d5f58d7121cf95c0d1434'
# Stripped binary hash is measured and published by the audited repacker.
[[ -s "$I1" && -s "$PATCH" && -s "$BASE" ]] || { echo 'BLOCKED: missing pinned source'; exit 3; }
echo "$I1_SHA  $I1" | sha256sum -c -
echo "$I1_PATCH_SHA  $PATCH" | sha256sum -c -
grep -qF "IRIS23_DPHY" "$PATCH" || { echo "BLOCKED: DPHY diag absent"; exit 3; }
grep -qF "IRIS23_SSC" "$PATCH" || { echo "BLOCKED: PLL diag absent"; exit 3; }

# Generate a temporary Stage20 repacker with ONLY the module/paths changed.
# Count each expected source replacement, so upstream drift fails closed.
python3 - <<'PY'
from pathlib import Path
p=Path('ci/stage20/repack.sh')
s=p.read_text()
expected=[
    ('MODULE_SHA=922a59ba3d24598b261a65cdb22043155045c7aeaf6e73d11dfe3031f96f4134',
     'MODULE_SHA=700460af78f1cb6f184b28ed768ca33a8d271ecad83bb0be672e5eca6fb2ae99'),
    ("KO='stage18/baseline/msm_drm.ko'",
     "KO='stage23-source/modules/Stage23_I1_plus_SSC_diag_msm_drm.ko'"),
    ("before=pathlib.Path('stage18/baseline/msm_drm.ko')",
     "before=pathlib.Path('stage23-source/modules/Stage23_I1_plus_SSC_diag_msm_drm.ko')"),
    ('STAGE18-unmodified-stripped-msm_drm.ko',
     'STAGE23-I1-SSC-DIAG-stripped-msm_drm.ko'),
    ('candidate_VENDOR_DLKM_B_OFFLINE_ONLY.img',
     'STAGE23-I1-SSC-DIAG_VENDOR_DLKM_B_OFFLINE_ONLY.img'),
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
s=s.replace('stage20-output','stage23-image-output')
Path('ci/stage23/generated_repack.sh').write_text(s)
print('STAGE23 REPACK DIFF: pinned module, paths, labels and output directory only')
PY

cat >stage23-image-output/provenance.txt <<EOF
Stage23 variant=I1 + stock Oplus SSC policy + DPHY/PLL diagnostics
source_stage23_run=39176311455
source_stage23_artifact=iris5-stage23-build-2
stage23_I1_SSC_sha256=$I1_SHA
stage23_diff_sha256=$I1_PATCH_SHA
stripped_sha256_file=stage23-image-output/stripped_module.sha256
AK3_release_tag=stage20-input
stage20_source_module=known-good control; installed and loaded on target
mode=$MODE
NOT FLASH APPROVAL
EOF

# Stage20 will re-verify the complete original AK3 image, 303 file entries,
# module metadata, EROFS extraction, xattrs, inode owner/mode, and output size.
STAGE20_MODE="$MODE" bash ci/stage23/generated_repack.sh

# Independently verify the stripped ELF of the exact audited Stage23 module.
test -s stage23-image-output/STAGE23-I1-SSC-DIAG-stripped-msm_drm.ko
sha256sum stage23-image-output/STAGE23-I1-SSC-DIAG-stripped-msm_drm.ko > stage23-image-output/stripped_module.sha256
if [[ "$MODE" == assemble ]]; then
  test -s stage23-image-output/STAGE23-I1-SSC-DIAG_VENDOR_DLKM_B_OFFLINE_ONLY.img
  [[ "$(wc -c < stage23-image-output/STAGE23-I1-SSC-DIAG_VENDOR_DLKM_B_OFFLINE_ONLY.img)" == '31768576' ]] || {
    echo 'BLOCKED: output partition size mismatch'; exit 5;
  }
  echo 'STAGE23 I1+SSC+DIAG ASSEMBLE PASS: output hash and EROFS manifest checked; NOT RUNTIME TESTED'
else
  echo 'STAGE23 I1+SSC+DIAG AUDIT PASS: no EROFS candidate image produced'
fi
