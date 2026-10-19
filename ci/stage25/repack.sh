#!/usr/bin/env bash
# Stage25 isolated I1+SSC plus read-only DPHY/PT/ESD/IOCTL/I2C traces, Stage20 EROFS/SELinux audit.
# Does NOT modify the original AK3, boot, vbmeta or phone.
set -euo pipefail
MODE="${STAGE25_IMAGE_MODE:-audit}"
[[ "$MODE" == audit || "$MODE" == assemble ]] || { echo 'BLOCKED: invalid mode'; exit 2; }
mkdir -p stage25-image-output
BASE='ci/stage20/repack.sh'
I1='stage25-source/modules/Stage25_PT_ESD_I2C_diag_msm_drm.ko'
PATCH='stage25-source/diffs/I1_plus_SSC_pt_esd_i2c_diag.diff'

# Pin Stage25 build #2 artifact (Stage22 I1+SSC + read-only DPHY/PLL logs).
# Independently check its module and source diff SHA256.
I1_SHA='e77d9c07e8c3d0c3138910e79931608fc15260c65062ba936d06fc9db39fa32a'
I1_PATCH_SHA='a86eae8f78401f7fb316f0723b3c5d40e70e5a0b688ada76d5ed22989172966b'
# Stripped binary hash is measured and published by the audited repacker.
[[ -s "$I1" && -s "$PATCH" && -s "$BASE" ]] || { echo 'BLOCKED: missing pinned source'; exit 3; }
echo "$I1_SHA  $I1" | sha256sum -c -
echo "$I1_PATCH_SHA  $PATCH" | sha256sum -c -
grep -qF "IRIS23_DPHY" "$PATCH" || { echo "BLOCKED: DPHY diag absent"; exit 3; }
grep -qF "IRIS23_SSC" "$PATCH" || { echo "BLOCKED: PLL diag absent"; exit 3; }
grep -qF "IRIS24_INTSTAT" "$PATCH" || { echo "BLOCKED: ESD PT-read diagnostics absent"; exit 3; }
grep -qF "IRIS24_REJECT_TYPE" "$PATCH" || { echo "BLOCKED: ioctl rejection diagnostics absent"; exit 3; }
grep -qF "IRIS25_I2C_S_WRITE" "$PATCH" || { echo "BLOCKED: I2C transport diagnostics absent"; exit 3; }

# Generate a temporary Stage20 repacker with ONLY the module/paths changed.
# Count each expected source replacement, so upstream drift fails closed.
python3 - <<'PY'
from pathlib import Path
p=Path('ci/stage20/repack.sh')
s=p.read_text()
expected=[
    ('MODULE_SHA=922a59ba3d24598b261a65cdb22043155045c7aeaf6e73d11dfe3031f96f4134',
     'MODULE_SHA=e77d9c07e8c3d0c3138910e79931608fc15260c65062ba936d06fc9db39fa32a'),
    ("KO='stage18/baseline/msm_drm.ko'",
     "KO='stage25-source/modules/Stage25_PT_ESD_I2C_diag_msm_drm.ko'"),
    ("before=pathlib.Path('stage18/baseline/msm_drm.ko')",
     "before=pathlib.Path('stage25-source/modules/Stage25_PT_ESD_I2C_diag_msm_drm.ko')"),
    ('STAGE18-unmodified-stripped-msm_drm.ko',
     'STAGE25-I1-SSC-PT-ESD-I2C-stripped-msm_drm.ko'),
    ('candidate_VENDOR_DLKM_B_OFFLINE_ONLY.img',
     'STAGE25-I1-SSC-PT-ESD-I2C_VENDOR_DLKM_B_OFFLINE_ONLY.img'),
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
s=s.replace('stage20-output','stage25-image-output')
Path('ci/stage25/generated_repack.sh').write_text(s)
print('STAGE25 REPACK DIFF: pinned module, paths, labels and output directory only')
PY

cat >stage25-image-output/provenance.txt <<EOF
Stage25 variant=I1 + Oplus SSC + DPHY/PLL + PT/ESD/IOCTL/I2C diagnostics
source_stage25_run=39184647777
source_stage25_artifact=iris5-stage25--2
stage25_I1_SSC_sha256=$I1_SHA
stage25_diff_sha256=$I1_PATCH_SHA
stripped_sha256_file=stage25-image-output/stripped_module.sha256
AK3_release_tag=stage20-input
stage20_source_module=known-good control; installed and loaded on target
mode=$MODE
NOT FLASH APPROVAL
EOF

# Stage20 will re-verify the complete original AK3 image, 303 file entries,
# module metadata, EROFS extraction, xattrs, inode owner/mode, and output size.
STAGE20_MODE="$MODE" bash ci/stage25/generated_repack.sh

# Independently verify the stripped ELF of the exact audited Stage25 module.
test -s stage25-image-output/STAGE25-I1-SSC-PT-ESD-I2C-stripped-msm_drm.ko
sha256sum stage25-image-output/STAGE25-I1-SSC-PT-ESD-I2C-stripped-msm_drm.ko > stage25-image-output/stripped_module.sha256
if [[ "$MODE" == assemble ]]; then
  test -s stage25-image-output/STAGE25-I1-SSC-PT-ESD-I2C_VENDOR_DLKM_B_OFFLINE_ONLY.img
  [[ "$(wc -c < stage25-image-output/STAGE25-I1-SSC-PT-ESD-I2C_VENDOR_DLKM_B_OFFLINE_ONLY.img)" == '31768576' ]] || {
    echo 'BLOCKED: output partition size mismatch'; exit 5;
  }
  echo 'STAGE25 I1+SSC+DIAG ASSEMBLE PASS: output hash and EROFS manifest checked; NOT RUNTIME TESTED'
else
  echo 'STAGE25 I1+SSC+DIAG AUDIT PASS: no EROFS candidate image produced'
fi
