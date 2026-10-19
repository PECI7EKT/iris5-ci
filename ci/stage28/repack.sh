#!/usr/bin/env bash
# Stage28: Stage27 plus PT timeout/error propagation and serialized panel TX, Stage20 EROFS/SELinux audit.
# Does NOT modify the original AK3, boot, vbmeta or phone.
set -euo pipefail
MODE="${STAGE28_IMAGE_MODE:-audit}"
[[ "$MODE" == audit || "$MODE" == assemble ]] || { echo 'BLOCKED: invalid mode'; exit 2; }
mkdir -p stage28-image-output
BASE='ci/stage20/repack.sh'
I1='stage28-source/modules/Stage28_PT_FIX_msm_drm.ko'
PATCH='stage28-source/diffs/I1_plus_SSC_pt_esd_i2c_host_gpio_ptfix.diff'

# Pin Stage28 build #2 artifact (Stage22 I1+SSC + read-only DPHY/PLL logs).
# Independently check its module and source diff SHA256.
I1_SHA='df520ef61e1b67b3f0cfb083807bb1e0a914c6f9a34c7130c97e1ac526219c14'
I1_PATCH_SHA='3e96a362becfb9ff7fee467d6712a507da5bec908f2cb39f550bb2e71ce0121a'
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
grep -qF "STAGE28_PT_RX_TIMEOUT" "$PATCH" || { echo "BLOCKED: Stage28 DCS read timeout handling absent"; exit 3; }
grep -qF "mutex_init(&panel->panel_tx_lock)" "$PATCH" || { echo "BLOCKED: Stage28 panel tx mutex init absent"; exit 3; }
grep -qF "return _iris_pt_write_panel_cmd(panel, cmdset)" "$PATCH" || { echo "BLOCKED: Stage28 PT error propagation absent"; exit 3; }

# Generate a temporary Stage20 repacker with ONLY the module/paths changed.
# Count each expected source replacement, so upstream drift fails closed.
python3 - <<'PY'
from pathlib import Path
p=Path('ci/stage20/repack.sh')
s=p.read_text()
expected=[
    ('MODULE_SHA=922a59ba3d24598b261a65cdb22043155045c7aeaf6e73d11dfe3031f96f4134',
     'MODULE_SHA=df520ef61e1b67b3f0cfb083807bb1e0a914c6f9a34c7130c97e1ac526219c14'),
    ("KO='stage18/baseline/msm_drm.ko'",
     "KO='stage28-source/modules/Stage28_PT_FIX_msm_drm.ko'"),
    ("before=pathlib.Path('stage18/baseline/msm_drm.ko')",
     "before=pathlib.Path('stage28-source/modules/Stage28_PT_FIX_msm_drm.ko')"),
    ('STAGE18-unmodified-stripped-msm_drm.ko',
     'STAGE28-PT-ERRORLOCK-FIX-stripped-msm_drm.ko'),
    ('candidate_VENDOR_DLKM_B_OFFLINE_ONLY.img',
     'STAGE28-PT-ERRORLOCK-FIX_VENDOR_DLKM_B_OFFLINE_ONLY.img'),
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
s=s.replace('stage20-output','stage28-image-output')
Path('ci/stage28/generated_repack.sh').write_text(s)
print('STAGE28 REPACK DIFF: pinned module, paths, labels and output directory only')
PY

cat >stage28-image-output/provenance.txt <<EOF
Stage28 variant=Stage27 diagnostics + TX mutex + PT error propagation + RX timeout/length checks
source_stage28_run=39289555117
source_stage28_artifact=iris5-stage28--3
stage28_I1_SSC_sha256=$I1_SHA
stage28_diff_sha256=$I1_PATCH_SHA
stripped_sha256_file=stage28-image-output/stripped_module.sha256
AK3_release_tag=stage20-input
stage20_source_module=known-good control; installed and loaded on target
mode=$MODE
NOT FLASH APPROVAL
EOF

# Stage20 will re-verify the complete original AK3 image, 303 file entries,
# module metadata, EROFS extraction, xattrs, inode owner/mode, and output size.
STAGE20_MODE="$MODE" bash ci/stage28/generated_repack.sh

# Independently verify the stripped ELF of the exact audited Stage28 module.
test -s stage28-image-output/STAGE28-PT-ERRORLOCK-FIX-stripped-msm_drm.ko
sha256sum stage28-image-output/STAGE28-PT-ERRORLOCK-FIX-stripped-msm_drm.ko > stage28-image-output/stripped_module.sha256
if [[ "$MODE" == assemble ]]; then
  test -s stage28-image-output/STAGE28-PT-ERRORLOCK-FIX_VENDOR_DLKM_B_OFFLINE_ONLY.img
  [[ "$(wc -c < stage28-image-output/STAGE28-PT-ERRORLOCK-FIX_VENDOR_DLKM_B_OFFLINE_ONLY.img)" == '31768576' ]] || {
    echo 'BLOCKED: output partition size mismatch'; exit 5;
  }
  echo 'STAGE28 I1+SSC+DIAG ASSEMBLE PASS: output hash and EROFS manifest checked; NOT RUNTIME TESTED'
else
  echo 'STAGE28 I1+SSC+DIAG AUDIT PASS: no EROFS candidate image produced'
fi
