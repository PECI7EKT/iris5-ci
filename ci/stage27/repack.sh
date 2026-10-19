#!/usr/bin/env bash
# Stage27 I1+SSC and read-only DPHY/PT/ESD/IOCTL/I2C/DSI/GPIO tracing, Stage20 EROFS/SELinux audit.
# Does NOT modify the original AK3, boot, vbmeta or phone.
set -euo pipefail
MODE="${STAGE27_IMAGE_MODE:-audit}"
[[ "$MODE" == audit || "$MODE" == assemble ]] || { echo 'BLOCKED: invalid mode'; exit 2; }
mkdir -p stage27-image-output
BASE='ci/stage20/repack.sh'
I1='stage27-source/modules/Stage27_WAKE_PT_ESD_diag_msm_drm.ko'
PATCH='stage27-source/diffs/I1_plus_SSC_pt_esd_i2c_host_gpio_diag.diff'

# Pin Stage27 build #2 artifact (Stage22 I1+SSC + read-only DPHY/PLL logs).
# Independently check its module and source diff SHA256.
I1_SHA='fcf3c442046627af2bc312fa4eb5ca2453456d0357a2a638f3f7490004df1d8f'
I1_PATCH_SHA='b2fe9645cc8ced3d8ff4c1d99e6e78cb21b0d59fa8b01f44c0b60e5cb30c587a'
# Stripped binary hash is measured and published by the audited repacker.
[[ -s "$I1" && -s "$PATCH" && -s "$BASE" ]] || { echo 'BLOCKED: missing pinned source'; exit 3; }
echo "$I1_SHA  $I1" | sha256sum -c -
echo "$I1_PATCH_SHA  $PATCH" | sha256sum -c -
grep -qF "IRIS23_DPHY" "$PATCH" || { echo "BLOCKED: DPHY diag absent"; exit 3; }
grep -qF "IRIS23_SSC" "$PATCH" || { echo "BLOCKED: PLL diag absent"; exit 3; }
grep -qF "IRIS24_INTSTAT" "$PATCH" || { echo "BLOCKED: ESD PT-read diagnostics absent"; exit 3; }
grep -qF "IRIS24_REJECT_TYPE" "$PATCH" || { echo "BLOCKED: ioctl rejection diagnostics absent"; exit 3; }
grep -qF "IRIS25_I2C_S_WRITE" "$PATCH" || { echo "BLOCKED: I2C transport diagnostics absent"; exit 3; }
grep -qF "IRIS26_DCS_HEADER" "$PATCH" || { echo "BLOCKED: DCS header diagnostics absent"; exit 3; }
grep -qF "IRIS26_OCP_HOST_SEND" "$PATCH" || { echo "BLOCKED: host DSI send diagnostics absent"; exit 3; }
grep -qF "IRIS27_ONEWIRE_DONE" "$PATCH" || { echo "BLOCKED: one-wire GPIO diagnostics absent"; exit 3; }
grep -qF "IRIS27_RESET_DONE" "$PATCH" || { echo "BLOCKED: reset GPIO diagnostics absent"; exit 3; }
grep -qF "IRIS27_EXIT_ATTEMPT" "$PATCH" || { echo "BLOCKED: ABYP per-attempt diagnostics absent"; exit 3; }

# Generate a temporary Stage20 repacker with ONLY the module/paths changed.
# Count each expected source replacement, so upstream drift fails closed.
python3 - <<'PY'
from pathlib import Path
p=Path('ci/stage20/repack.sh')
s=p.read_text()
expected=[
    ('MODULE_SHA=922a59ba3d24598b261a65cdb22043155045c7aeaf6e73d11dfe3031f96f4134',
     'MODULE_SHA=fcf3c442046627af2bc312fa4eb5ca2453456d0357a2a638f3f7490004df1d8f'),
    ("KO='stage18/baseline/msm_drm.ko'",
     "KO='stage27-source/modules/Stage27_WAKE_PT_ESD_diag_msm_drm.ko'"),
    ("before=pathlib.Path('stage18/baseline/msm_drm.ko')",
     "before=pathlib.Path('stage27-source/modules/Stage27_WAKE_PT_ESD_diag_msm_drm.ko')"),
    ('STAGE18-unmodified-stripped-msm_drm.ko',
     'STAGE27-I1-SSC-PT-ESD-I2C-DSI-GPIO-stripped-msm_drm.ko'),
    ('candidate_VENDOR_DLKM_B_OFFLINE_ONLY.img',
     'STAGE27-I1-SSC-PT-ESD-I2C-DSI-GPIO_VENDOR_DLKM_B_OFFLINE_ONLY.img'),
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
s=s.replace('stage20-output','stage27-image-output')
Path('ci/stage27/generated_repack.sh').write_text(s)
print('STAGE27 REPACK DIFF: pinned module, paths, labels and output directory only')
PY

cat >stage27-image-output/provenance.txt <<EOF
Stage27 variant=I1 + Oplus SSC + DPHY/PLL + PT/ESD/IOCTL/I2C/DSI/GPIO diagnostics
source_stage27_run=39226136499
source_stage27_artifact=iris5-stage27--2
stage27_I1_SSC_sha256=$I1_SHA
stage27_diff_sha256=$I1_PATCH_SHA
stripped_sha256_file=stage27-image-output/stripped_module.sha256
AK3_release_tag=stage20-input
stage20_source_module=known-good control; installed and loaded on target
mode=$MODE
NOT FLASH APPROVAL
EOF

# Stage20 will re-verify the complete original AK3 image, 303 file entries,
# module metadata, EROFS extraction, xattrs, inode owner/mode, and output size.
STAGE20_MODE="$MODE" bash ci/stage27/generated_repack.sh

# Independently verify the stripped ELF of the exact audited Stage27 module.
test -s stage27-image-output/STAGE27-I1-SSC-PT-ESD-I2C-DSI-GPIO-stripped-msm_drm.ko
sha256sum stage27-image-output/STAGE27-I1-SSC-PT-ESD-I2C-DSI-GPIO-stripped-msm_drm.ko > stage27-image-output/stripped_module.sha256
if [[ "$MODE" == assemble ]]; then
  test -s stage27-image-output/STAGE27-I1-SSC-PT-ESD-I2C-DSI-GPIO_VENDOR_DLKM_B_OFFLINE_ONLY.img
  [[ "$(wc -c < stage27-image-output/STAGE27-I1-SSC-PT-ESD-I2C-DSI-GPIO_VENDOR_DLKM_B_OFFLINE_ONLY.img)" == '31768576' ]] || {
    echo 'BLOCKED: output partition size mismatch'; exit 5;
  }
  echo 'STAGE27 I1+SSC+DIAG ASSEMBLE PASS: output hash and EROFS manifest checked; NOT RUNTIME TESTED'
else
  echo 'STAGE27 I1+SSC+DIAG AUDIT PASS: no EROFS candidate image produced'
fi
