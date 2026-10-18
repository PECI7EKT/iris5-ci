#!/usr/bin/env python3
"""Review-only Stage19 ABI gate: reuse the successful Stage18 symbol verifier.
This does not validate device operation, lifecycle timing, or flashed modules.
"""
import hashlib
import json
import pathlib
import subprocess
import sys

label, candidate = sys.argv[1:3]
root = pathlib.Path('ci-out')
out = root / 'stage19' / 'abi'
out.mkdir(parents=True, exist_ok=True)
module = pathlib.Path(candidate)
base = root / 'baseline' / 'msm_drm.ko'
base_hash = hashlib.sha256(base.read_bytes()).hexdigest()
sha = hashlib.sha256(module.read_bytes()).hexdigest()
proc = subprocess.run([sys.executable, 'ci/stage18/verify_display.py', str(module)],
                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
src_report = root / 'baseline_abi.json'
report = json.loads(src_report.read_text()) if src_report.exists() else {}
report.update({
    'stage': 19,
    'variant': label,
    'device_tested': False,
    'flash_approved': False,
    'reference_baseline_sha256': base_hash,
    'candidate_sha256': sha,
    'differs_from_compiled_baseline': sha != base_hash,
    'abi_verifier_exit_code': proc.returncode,
    'abi_verifier_stderr': proc.stderr[-2500:],
})
(out / f'{label}.json').write_text(json.dumps(report, indent=2) + '\n')
if proc.returncode != 0:
    print(f'BLOCKED: {label} ABI verifier rejected module: {proc.stderr}', file=sys.stderr)
    sys.exit(3)
if sha == base_hash:
    print(f'BLOCKED: {label} module binary identical to baseline (change not evidenced)', file=sys.stderr)
    sys.exit(4)
print(f'STAGE19 VARIANT ABI PASS: {label}: CRC {report["rebuilt_imports"]}/763, BTF, KCFI, vermagic; NOT runtime tested')
