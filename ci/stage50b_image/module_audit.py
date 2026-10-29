#!/usr/bin/env python3
"""Prove strip-debug does not alter retained module code, data or ABI."""
from pathlib import Path
from elftools.elf.elffile import ELFFile
from elftools.elf.relocation import RelocationSection
import hashlib
import importlib.util
import json
import sys


def retained(path):
    with Path(path).open('rb') as stream:
        elf = ELFFile(stream)
        data = {}
        relocations = {}
        kcfi = {}
        names = set()
        for symbol in elf.get_section_by_name('.symtab').iter_symbols():
            names.add(symbol.name)
            if symbol.name.startswith('__kcfi_typeid_'):
                kcfi[symbol.name] = symbol['st_value']
        for section in elf.iter_sections():
            name = section.name
            if not name or '.debug' in name or '.zdebug' in name or name in ('.symtab','.strtab','.shstrtab','.llvm_addrsig'):
                continue
            if isinstance(section,RelocationSection):
                symbols = elf.get_section(section['sh_link'])
                rows = []
                for rel in section.iter_relocations():
                    symbol = symbols.get_symbol(rel['r_info_sym'])
                    label = symbol.name
                    if symbol['st_info']['type'] == 'STT_SECTION':
                        label = 'section:'+elf.get_section(symbol['st_shndx']).name
                    rows.append([rel['r_offset'],rel['r_info_type'],label,symbol['st_value'],rel['r_addend']])
                relocations[name] = rows
            else:
                data[name] = {'size':section['sh_size'],'flags':section['sh_flags'],
                              'sha256':hashlib.sha256(section.data()).hexdigest()}
        return data,relocations,kcfi,names


def main(before, after, output):
    a,b = retained(before),retained(after)
    assert a[:3] == b[:3], 'retained section bytes, relocation meanings or KCFI IDs changed'
    required = ['iris44_host_diag','__tracepoint_iris44_host','__traceiter_iris44_host',
                'event_iris44_host','event_class_iris44_host','__event_iris44_host',
                'iris50b_observe','__param_iris50b_stats','__tracepoint_iris50b_observe','__event_iris50b_observe']
    for name in required:
        assert name in b[3],name
    parser = Path(__file__).resolve().parents[1]/'stage44/verify_binary.py'
    spec = importlib.util.spec_from_file_location('stage45_elf',parser)
    module = importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    source = module.inspect(Path(before));packed = module.inspect(Path(after))
    for key in ('versions','exports','undefined','modinfo','build_id','diagnostic_symbols','diagnostic_default_false'):
        assert source[key] == packed[key],key
    assert len(packed['versions'])==763 and len(packed['exports'])==94 and len(b[2])==490
    result = {'status':'PASS','operation':'llvm-objcopy-18 --strip-debug',
              'input_sha256':source['sha256'],'packed_sha256':packed['sha256'],
              'input_size':source['size'],'packed_size':packed['size'],
              'build_id':packed['build_id'],'version_entries':763,'exports':94,'kcfi_type_ids':490,
              'retained_sections':b[0],'retained_relocation_sections':sorted(b[1]),
              'diagnostic_symbols':packed['diagnostic_symbols'],'default_false':packed['diagnostic_default_false'],
              'modinfo':packed['modinfo']}
    Path(output).write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:result[k] for k in ('status','input_sha256','packed_sha256','packed_size','build_id')},indent=2))


if __name__ == '__main__':
    main(*sys.argv[1:])
