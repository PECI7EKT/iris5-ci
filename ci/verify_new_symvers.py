#!/usr/bin/env python3
"""Compare the 739 required original kernel CRCs to newly built kernel symvers."""
import csv
import sys
from pathlib import Path
p=Path(sys.argv[1]); symbols={}
for ln in p.read_text().splitlines():
    f=ln.split('\t')
    if len(f)!=5: raise SystemExit('Malformed generated kernel Module.symvers')
    if f[1] in symbols: raise SystemExit('Duplicate generated symbol '+f[1])
    symbols[f[1]]=f[0].lower()
count=0
with Path('ci/reference/symbol_comparison.csv').open(encoding='utf-8-sig',newline='') as fh:
    for row in csv.DictReader(fh):
        if row['kernel_symvers_status']!='MATCH': continue
        k=row['symbol']; want=row['reference_crc'].lower()
        if symbols.get(k)!=want:
            raise SystemExit(f'Generated ABI mismatch for {k}: {symbols.get(k)} != {want}')
        count+=1
assert count==739, count
print('NEW kernel foundation CRC: 739 / 739 MATCH')
