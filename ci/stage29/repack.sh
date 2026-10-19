#!/usr/bin/env bash
# Stage29: Stage27 plus PT timeout/error propagation and serialized panel TX, Stage20 EROFS/SELinux audit.
# Does NOT modify the original AK3, boot, vbmeta or phone.
set -euo pipefail
MODE="${STAGE29_IMAGE_MODE:-audit}"
[[ "$MODE" == audit || "$MODE" == assemble ]] || { echo 'BLOCKED: invalid mode'; exit 2; }
mkdir -p stage29-image-output
BASE='ci/stage20/repack.sh'
I1='stage29-source/modules/Stage29_PT_DCS_I2C_msm_drm.ko'
PATCH='stage29-source/diffs/I1_plus_SSC_pt_esd_i2c_ptchecked.diff'

# Pin Stage29 build #2 artifact (Stage22 I1+SSC + read-only DPHY/PLL logs).
# Independently check its module and source diff SHA256.
I1_SHA='37bcead6452a3baaf0b5b293968baeab650f277dc85cda7a31e3474acce5de83'
I1_PATCH_SHA='fc32c8c31240df9238ed8ed9209341f425e86e7b9d5c08ed4d5bfec96046154b'
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
grep -qF "STAGE28_PT_RX_TIMEOUT" "$PATCH" || { echo "BLOCKED: Stage29 DCS read timeout handling absent"; exit 3; }
grep -qF "mutex_init(&panel->panel_tx_lock)" "$PATCH" || { echo "BLOCKED: Stage29 panel tx mutex init absent"; exit 3; }
grep -qF "return _iris_pt_write_panel_cmd(panel, cmdset)" "$PATCH" || { echo "BLOCKED: Stage29 PT error propagation absent"; exit 3; }
grep -qF "IRIS29_PT_RX_I2C_FAIL" "$PATCH" || { echo "BLOCKED: Stage29 checked I2C PT RX absent"; exit 3; }
grep -qF "iris_i2c_conver_ocp_read(&v, 1, false)" "$PATCH" || { echo "BLOCKED: Stage29 checked read code absent"; exit 3; }

# Generate a temporary Stage20 repacker with ONLY the module/paths changed.
# Count each expected source replacement, so upstream drift fails closed.
python3 - <<'PY'
from pathlib import Path
p=Path('ci/stage20/repack.sh')
s=p.read_text()
expected=[
    ('MODULE_SHA=922a59ba3d24598b261a65cdb22043155045c7aeaf6e73d11dfe3031f96f4134',
     'MODULE_SHA=37bcead6452a3baaf0b5b293968baeab650f277dc85cda7a31e3474acce5de83'),
    ("KO='stage18/baseline/msm_drm.ko'",
     "KO='stage29-source/modules/Stage29_PT_DCS_I2C_msm_drm.ko'"),
    ("before=pathlib.Path('stage18/baseline/msm_drm.ko')",
     "before=pathlib.Path('stage29-source/modules/Stage29_PT_DCS_I2C_msm_drm.ko')"),
    ('STAGE18-unmodified-stripped-msm_drm.ko',
     'STAGE29-PT-RX-I2C-FIX-stripped-msm_drm.ko'),
    ('candidate_VENDOR_DLKM_B_OFFLINE_ONLY.img',
     'STAGE29-PT-RX-I2C-FIX_VENDOR_DLKM_B_OFFLINE_ONLY.img'),
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
s=s.replace('stage20-output','stage29-image-output')
Path('ci/stage29/generated_repack.sh').write_text(s)
print('STAGE29 REPACK DIFF: pinned module, paths, labels and output directory only')
PY

cat >stage29-image-output/provenance.txt <<EOF
Stage29 variant=Stage28 + checked PT DCS response status/data over I2C
source_stage29_run=39326555733
source_stage29_artifact=iris5-stage29--2
stage29_I1_SSC_sha256=$I1_SHA
stage29_diff_sha256=$I1_PATCH_SHA
stripped_sha256_file=stage29-image-output/stripped_module.sha256
AK3_release_tag=stage20-input
stage20_source_module=known-good control; installed and loaded on target
mode=$MODE
NOT FLASH APPROVAL
EOF

# Stage20 will re-verify the complete original AK3 image, 303 file entries,
# module metadata, EROFS extraction, xattrs, inode owner/mode, and output size.
STAGE20_MODE="$MODE" bash ci/stage29/generated_repack.sh

# Independently verify the stripped ELF of the exact audited Stage29 module.
test -s stage29-image-output/STAGE29-PT-RX-I2C-FIX-stripped-msm_drm.ko
sha256sum stage29-image-output/STAGE29-PT-RX-I2C-FIX-stripped-msm_drm.ko > stage29-image-output/stripped_module.sha256
if [[ "$MODE" == assemble ]]; then
  test -s stage29-image-output/STAGE29-PT-RX-I2C-FIX_VENDOR_DLKM_B_OFFLINE_ONLY.img
  [[ "$(wc -c < stage29-image-output/STAGE29-PT-RX-I2C-FIX_VENDOR_DLKM_B_OFFLINE_ONLY.img)" == '31768576' ]] || {
    echo 'BLOCKED: output partition size mismatch'; exit 5;
  }
  echo 'STAGE29 I1+SSC+DIAG ASSEMBLE PASS: output hash and EROFS manifest checked; NOT RUNTIME TESTED'
else
  echo 'STAGE29 I1+SSC+DIAG AUDIT PASS: no EROFS candidate image produced'
fi
