#!/usr/bin/env python3
"""Exact source SHA gate before compiling either variant."""
from pathlib import Path
import hashlib,json,sys
base=Path(sys.argv[1]);variant=sys.argv[2];out=Path(sys.argv[3])
m=json.loads((Path(__file__).parent/'source_manifest.json').read_text())
expected=dict(m['stage36_files'])
if variant=='stage44':expected.update(m['stage44_files'])
assert variant in ('stage36','stage44')
actual={}
for rel,h in expected.items():
 p=base/rel;assert p.is_file(),f'missing source: {p}'
 actual[rel]=hashlib.sha256(p.read_bytes()).hexdigest()
 assert actual[rel]==h,f'{variant} source differs: {rel}: {actual[rel]} != {h}'
out.parent.mkdir(parents=True,exist_ok=True)
out.write_text(json.dumps({'variant':variant,'verified_files':len(expected),'files':actual},indent=2)+'\n')
print(f'{variant}: {len(expected)} exact source files PASS')
