#!/usr/bin/env python3
"""Full module ABI gate against the bit-identical rebuilt Stage44."""
from pathlib import Path
import hashlib,importlib.util,json,re,sys
from elftools.elf.elffile import ELFFile
S=Path('ci/stage44/verify_binary.py')
if not S.exists():S=Path(__file__).resolve().parents[1]/'stage45/ci/ci/stage44/verify_binary.py'
spec=importlib.util.spec_from_file_location('stage44_inspect',S);helper=importlib.util.module_from_spec(spec);spec.loader.exec_module(helper)
def extras(p):
 with p.open('rb') as f:
  elf=ELFFile(f);syms=list(elf.get_section_by_name('.symtab').iter_symbols())
  names={s.name for s in syms}
  param=next(s for s in syms if s.name=='iris50b_observe') if 'iris50b_observe' in names else None
  default=None
  if param:
   sec=elf.get_section(param['st_shndx']);o=param['st_value']-sec['sh_addr']
   default=sec['sh_type']=='SHT_NOBITS' or not any(sec.data()[o:o+param['st_size']])
  return {'kcfi':{s.name:s['st_value'] for s in syms if s.name.startswith('__kcfi_typeid_')},'observe_symbols':sorted(n for n in names if 'iris50b' in n),'default_false':default}
def main(out):
 abi=out/'abi';abi.mkdir(exist_ok=True)
 a=helper.inspect(out/'modules/STAGE44_BASELINE_msm_drm.ko');b=helper.inspect(out/'modules/STAGE50B_OBSERVE_msm_drm.ko')
 x=extras(Path(a['path']));y=extras(Path(b['path']));providers=json.loads((abi/'authentic_providers.json').read_text())
 errors=[];checks={}
 def ck(n,v):
  checks[n]=bool(v)
  if not v:errors.append(n)
 ck('Stage44 baseline exact SHA256',a['sha256']=='f1239ce975972d43390a8a377eed6ddee59d3022f8b60223eaed51f45019947b')
 for key in ('machine','elf_type','elfclass','undefined','versions','exports'):
  ck('unchanged '+key,a[key]==b[key])
 for key in ('vermagic','depends','name','retpoline'):
  ck('unchanged modinfo '+key,a['modinfo'].get(key)==b['modinfo'].get(key))
 rows=[]
 for n,c in b['versions'].items():
  provider=providers.get(n);match=bool(provider and provider['crc']==c)
  rows.append({'symbol':n,'crc':c,'provider':provider,'status':'MATCH' if match else 'FAIL'})
 ck('all genuine provider CRCs',all(r['status']=='MATCH' for r in rows))
 for name in ('__tracepoint_iris50b_observe','__traceiter_iris50b_observe','event_iris50b_observe','__event_iris50b_observe','__param_iris50b_observe','__param_iris50b_stats'):
  ck('registered '+name,name in y['observe_symbols'])
 ck('new diagnostics default OFF',y['default_false'] is True)
 for name in ('iris50b_observe:bool',):ck('module parameter '+name,name in b['modinfo'].get('parmtype',[]))
 ck('new module parameters only',set(b['modinfo'].get('parmtype',[]))-set(a['modinfo'].get('parmtype',[]))=={'iris50b_observe:bool'})
 common=x['kcfi'].keys()&y['kcfi'].keys()
 changed={n:[x['kcfi'][n],y['kcfi'][n]] for n in common if x['kcfi'][n]!=y['kcfi'][n]}
 ck('retained KCFI IDs unchanged',not changed)
 for name in ('.BTF','.BTF.ext'):
  ck('nonempty '+name,any(s['name']==name and s['size']>0 for s in b['sections']))
 cfg=dict(re.findall(r'^(CONFIG_\w+)=(.*)$',(out/'config/kernel.config').read_text(),re.M))
 required=['CONFIG_CFI_CLANG','CONFIG_LTO_CLANG_THIN','CONFIG_MODVERSIONS','CONFIG_DEBUG_INFO_BTF','CONFIG_DEBUG_INFO_BTF_MODULES','CONFIG_MODULE_SIG_PROTECT']
 for n in required:ck(n,cfg.get(n)=='y')
 cmds='\n'.join(p.read_text() for p in (out/'config').glob('*.cmd'))
 for flag in ('-flto=thin','-fsanitize=kcfi'):ck('actual compile '+flag,flag in cmds)
 ck('exact original Clang identity', '11368308' in b['comment'] and '477610d4d0d988e69dbc3fae4fe86bff3f07f2b5' in b['comment'])
 ck('original Stage44 diagnostics retained',set(a['diagnostic_symbols'])<=set(b['diagnostic_symbols']))
 for name,obj in [('stage44',a),('stage50b',b),('provider_crc',rows),('stage50b_extras',y)]:
  (abi/(name+'.json')).write_text(json.dumps(obj,indent=2)+'\n')
 result={'status':'FAIL' if errors else 'PASS','errors':errors,'checks':checks,'import_count':len(b['undefined']),'crc_count':len(rows),'crc_match':sum(r['status']=='MATCH' for r in rows),'export_count':len(b['exports']),'retained_kcfi_count':len(common),'changed_kcfi':changed,'added_kcfi':sorted(y['kcfi'].keys()-x['kcfi'].keys()),'removed_kcfi':sorted(x['kcfi'].keys()-y['kcfi'].keys()),'sha256':b['sha256'],'build_id':b['build_id'],'size':b['size'],'scope':'Full module and static compatibility; NO install approval; NOT DEVICE TESTED'}
 (abi/'compatibility_manifest.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
 if errors:raise SystemExit(1)
if __name__=='__main__':main(Path(sys.argv[1]))
