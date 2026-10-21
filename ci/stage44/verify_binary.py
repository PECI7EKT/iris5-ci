#!/usr/bin/env python3
"""Validate full AArch64 modules against authentic kernel and provider CRCs.

This is a build/static ABI gate, not permission to install or a runtime test.
"""
from pathlib import Path
import csv
import hashlib
import json
import re
import sys
from elftools.elf.elffile import ELFFile


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inspect(path):
    with path.open('rb') as stream:
        elf = ELFFile(stream)
        sections = list(elf.iter_sections())
        symtab = elf.get_section_by_name('.symtab')
        syms = list(symtab.iter_symbols())
        versions_section = elf.get_section_by_name('__versions')
        assert versions_section is not None, 'missing __versions'
        raw = versions_section.data()
        assert len(raw) % 64 == 0
        versions = {}
        for offset in range(0, len(raw), 64):
            name = raw[offset+8:offset+64].split(b'\0', 1)[0].decode()
            assert name not in versions
            versions[name] = f'0x{int.from_bytes(raw[offset:offset+8], "little") & 0xffffffff:08x}'
        exports = {}
        for symbol in syms:
            if not symbol.name.startswith('__crc_'):
                continue
            index = symbol['st_shndx']
            if index == 'SHN_ABS':
                value = symbol['st_value']
            else:
                section = sections[index]
                offset = symbol['st_value'] - section['sh_addr']
                value = int.from_bytes(section.data()[offset:offset+4], 'little')
            exports[symbol.name[6:]] = f'0x{value & 0xffffffff:08x}'
        names = {symbol.name for symbol in syms}
        undefined = sorted({symbol.name for symbol in syms if symbol['st_shndx'] == 'SHN_UNDEF' and symbol.name})
        modinfo = {}
        for item in elf.get_section_by_name('.modinfo').data().split(b'\0'):
            if b'=' in item:
                key, value = item.decode().split('=', 1)
                modinfo.setdefault(key, []).append(value)
        build_id = None
        for section in sections:
            if section['sh_type'] == 'SHT_NOTE':
                for note in section.iter_notes():
                    if note['n_type'] == 'NT_GNU_BUILD_ID':
                        build_id = note['n_desc']
        parameter = next((s for s in syms if s.name == 'iris44_host_diag'), None)
        parameter_zero = None
        if parameter is not None and isinstance(parameter['st_shndx'], int):
            section = sections[parameter['st_shndx']]
            if section['sh_type'] == 'SHT_NOBITS':
                parameter_zero = True
            else:
                off = parameter['st_value'] - section['sh_addr']
                parameter_zero = not any(section.data()[off:off+parameter['st_size']])
        return {
            'path': str(path), 'sha256': sha(path), 'size': path.stat().st_size,
            'build_id': build_id, 'machine': elf['e_machine'], 'elf_type': elf['e_type'],
            'elfclass': elf.elfclass, 'modinfo': modinfo,
            'comment': elf.get_section_by_name('.comment').data().decode().replace('\0', '\n').strip(),
            'versions': dict(sorted(versions.items())), 'exports': dict(sorted(exports.items())),
            'undefined': undefined, 'kcfi_symbols': sum(n.startswith('__kcfi_') for n in names),
            'sections': [{'name': s.name, 'type': s['sh_type'], 'size': s['sh_size']} for s in sections],
            'relocation_sections': sum(s['sh_type'] in ('SHT_RELA', 'SHT_REL') for s in sections),
            'diagnostic_symbols': sorted(n for n in names if 'iris44' in n),
            'diagnostic_default_false': parameter_zero,
        }


def main(out):
    abi = out/'abi'
    abi.mkdir(exist_ok=True)
    providers = {}
    for path in sorted((out/'symbols').glob('*.Module.symvers')):
        if path.name.startswith(('stage36.', 'stage44.')):
            continue
        for line in path.read_text().splitlines():
            fields = line.split()
            if len(fields) >= 4:
                row = {'crc': f'0x{int(fields[0], 16):08x}', 'symbol': fields[1],
                       'provider': fields[2], 'export_type': fields[3], 'symvers': path.name,
                       'namespace': fields[4] if len(fields) > 4 else ''}
                if fields[1] in providers:
                    assert providers[fields[1]]['crc'] == row['crc'], ('conflicting providers', row)
                providers[fields[1]] = row
    (abi/'authentic_providers.json').write_text(json.dumps(providers, indent=2)+'\n')
    reports = {}
    errors = []
    for variant in ('STAGE36_REFERENCE', 'STAGE36_REBUILT', 'STAGE44_DIAGNOSTIC'):
        result = inspect(out/'modules'/f'{variant}_msm_drm.ko')
        reports[variant] = result
        rows = []
        for name, crc in result['versions'].items():
            provider = providers.get(name)
            status = 'MATCH' if provider and provider['crc'] == crc else 'MISMATCH' if provider else 'MISSING'
            rows.append({'symbol': name, 'module_crc': crc, 'status': status,
                         'provider_crc': provider['crc'] if provider else '',
                         'provider': provider['provider'] if provider else '',
                         'symvers': provider['symvers'] if provider else ''})
            if status != 'MATCH':
                errors.append(f'{variant}: {name}: {status}')
        result['crc_counts'] = {status: sum(r['status'] == status for r in rows) for status in ('MATCH', 'MISMATCH', 'MISSING')}
        for name in result['undefined']:
            if name not in result['versions']:
                errors.append(f'{variant}: undefined import lacks CRC: {name}')
        with (abi/f'{variant}_imports.csv').open('w', newline='') as stream:
            writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)
        (abi/f'{variant}.json').write_text(json.dumps(result, indent=2)+'\n')
        if result['machine'] != 'EM_AARCH64' or result['elfclass'] != 64 or result['elf_type'] != 'ET_REL':
            errors.append(f'{variant}: unexpected architecture/type')
        if not any(s['name'] == '.BTF' and s['size'] > 0 for s in result['sections']):
            errors.append(f'{variant}: missing BTF')
        if not result['kcfi_symbols']:
            errors.append(f'{variant}: missing KCFI symbols')
        if '477610d4d0d988e69dbc3fae4fe86bff3f07f2b5' not in result['comment'] or '11368308' not in result['comment']:
            errors.append(f'{variant}: unexpected compiler identity')
    reference = reports['STAGE36_REFERENCE']
    baseline = reports['STAGE36_REBUILT']
    candidate = reports['STAGE44_DIAGNOSTIC']
    for variant, result in reports.items():
        if result['modinfo'].get('vermagic') != reference['modinfo'].get('vermagic'):
            errors.append(f'{variant}: vermagic mismatch')
        if result['modinfo'].get('depends') != reference['modinfo'].get('depends'):
            errors.append(f'{variant}: dependency mismatch')
        if result['exports'] != reference['exports']:
            errors.append(f'{variant}: exported symbols/CRC mismatch')
    if baseline['versions'] != reference['versions']:
        errors.append('Stage36 reproduced imports/CRC differ from historical reference')
    removed = sorted(set(baseline['versions']) - set(candidate['versions']))
    added = sorted(set(candidate['versions']) - set(baseline['versions']))
    changed = {n: {'stage36': baseline['versions'][n], 'stage44': candidate['versions'][n]}
               for n in baseline['versions'].keys() & candidate['versions'].keys()
               if baseline['versions'][n] != candidate['versions'][n]}
    if removed or changed:
        errors.append('Stage44 removes imports or changes retained import CRC')
    required = ['iris44_host_diag', '__param_iris44_host_diag', '__tracepoint_iris44_host',
                '__traceiter_iris44_host', 'event_iris44_host', '__event_iris44_host']
    for name in required:
        if name not in candidate['diagnostic_symbols']:
            errors.append(f'missing diagnostic symbol: {name}')
    if candidate['diagnostic_default_false'] is not True:
        errors.append('diagnostic parameter is not default false')
    if 'iris44_host_diag:bool' not in candidate['modinfo'].get('parmtype', []):
        errors.append('diagnostic bool module parameter metadata missing')
    config = (out/'config/kernel.config').read_text()
    config_values = dict(re.findall(r'^(CONFIG_\w+)=(.*)$', config, re.M))
    required_config = ['CONFIG_CFI_CLANG', 'CONFIG_LTO_CLANG_THIN', 'CONFIG_MODVERSIONS',
                       'CONFIG_DEBUG_INFO_BTF', 'CONFIG_DEBUG_INFO_BTF_MODULES', 'CONFIG_MODULE_SIG_PROTECT']
    for name in required_config:
        if config_values.get(name) != 'y':
            errors.append(f'required kernel feature absent: {name}')
    commands = '\n'.join(p.read_text() for p in (out/'config').glob('*.cmd'))
    for flag in ('-flto=thin', '-fsanitize=kcfi'):
        if flag not in commands:
            errors.append(f'actual compile command lacks {flag}')
    summary = {'status': 'FAIL' if errors else 'PASS', 'errors': errors,
               'scope': 'Full external-module build and static ABI validation; NOT DEVICE TESTED; NOT installation approval',
               'added_imports': {n: providers.get(n) for n in added}, 'removed_imports': removed,
               'changed_import_crc': changed, 'config': {n: config_values.get(n) for n in required_config},
               'modules': {k: {n: v[n] for n in ('sha256', 'size', 'build_id', 'modinfo', 'crc_counts', 'kcfi_symbols', 'diagnostic_symbols')}
                           for k, v in reports.items()},
               'export_count': len(candidate['exports']), 'reference_import_count': len(reference['versions']),
               'candidate_import_count': len(candidate['versions'])}
    (abi/'compatibility_manifest.json').write_text(json.dumps(summary, indent=2)+'\n')
    print(json.dumps(summary, indent=2))
    if errors:
        raise SystemExit(1)


if __name__ == '__main__':
    main(Path(sys.argv[1]))
