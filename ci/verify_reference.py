#!/usr/bin/env python3
"""Check the complete stage-16 reference without executing third-party scripts."""
import csv
import hashlib
import json
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REF = ROOT / 'reference'
OUT = Path('ci-out')
OUT.mkdir(exist_ok=True)
EXPECTED = {
    'Module.symvers': '25cd641cd235bb7d010a77a4c6592447186358247e26cf51f99370788f9bc05c',
    'original_Image.config': '36601710e74d1f09bd769855dfdb5cd5cd85b7c2781fd83ddafc4d3aade058f0',
}
for name, want in EXPECTED.items():
    actual = hashlib.sha256((REF/name).read_bytes()).hexdigest()
    assert actual == want, f'{name} SHA mismatch: {actual} != {want}'

entries = {}
with (REF/'Module.symvers').open(encoding='ascii') as stream:
    for number, line in enumerate(stream, 1):
        fields = line.rstrip('\n').split('\t')
        assert len(fields) == 5, f'Bad Module.symvers line {number}'
        crc, symbol, provider, export_type, namespace = fields
        assert symbol not in entries, f'duplicate symbol: {symbol}'
        assert crc.startswith('0x') and len(crc) == 10
        entries[symbol] = {'crc':crc.lower(), 'provider':provider, 'export':export_type, 'namespace':namespace}
assert len(entries) == 18750, f'Unexpected record count {len(entries)}'

counts=Counter()
with (REF/'symbol_comparison.csv').open(encoding='utf-8-sig',newline='') as stream:
    rows=list(csv.DictReader(stream))
assert len(rows)==763, f'Expected 763 reference entries, found {len(rows)}'
assert len({r['symbol'] for r in rows})==763
for row in rows:
    symbol=row['symbol']; expected=row['reference_crc'].lower()
    kernel=entries.get(symbol)
    if kernel is None:
        assert row['kernel_symvers_status']=='ABSENT', f'unexpected absent {symbol}'
        assert row['original_archive_provider_crc'].lower()==expected, f'bad original provider {symbol}'
        assert row['resolved_crc_status']=='MATCH'
        counts['external']+=1
    else:
        assert row['kernel_symvers_status']=='MATCH', f'wrong reference status {symbol}'
        assert kernel['crc']==expected, f'CRC mismatch: {symbol}'
        assert row['kernel_crc'].lower()==expected, f'CSV CRC mismatch {symbol}'
        assert row['resolved_crc_status']=='MATCH'
        counts['kernel']+=1
assert counts==Counter(kernel=739,external=24),counts

config=(REF/'original_Image.config').read_text()
for required in ('CONFIG_MODVERSIONS=y','CONFIG_CFI_CLANG=y','CONFIG_LTO_CLANG_THIN=y','CONFIG_DEBUG_INFO_BTF=y','CONFIG_DEBUG_INFO_BTF_MODULES=y','CONFIG_MODULE_SIG_PROTECT=y'):
    assert required in config, f'missing original config flag {required}'

result={'status':'PASS','kernel_imports':739,'external_imports':24,'total':763,
        'mismatch':0,'unresolved':0,'kernel_symvers_records':len(entries),
        'original_config_sha256':EXPECTED['original_Image.config']}
(OUT/'reference_check.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))
