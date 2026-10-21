#!/usr/bin/env python3
"""Verify pinned historical recipe, patch and downloaded Stage36; no build bypass."""
from pathlib import Path
import hashlib,json
R=Path.cwd();S=Path(__file__).resolve().parent
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
m=json.loads((S/'source_manifest.json').read_text())
assert sha(S/'stage44_abyp_host_diag.patch')==m['patch_sha256']
for rel,h in m['recipe_inputs'].items():assert sha(R/rel)==h,(rel,'CI recipe drift')
assert sha(R/'stage36-reference/diffs/I1_plus_SSC_pt_esd_i2c_ptchecked.diff')==m['stage36_cumulative_sha256']
assert sha(R/'stage36-reference/modules/Stage36_VBLANK_GUARD_msm_drm.ko')==m['stage36_module_sha256']
print('Pinned recipe, Stage44 patch and historical Stage36 artifact: PASS')
