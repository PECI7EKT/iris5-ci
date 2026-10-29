#!/usr/bin/env python3
from pathlib import Path
import csv
import hashlib
import json
import os
import stat
import sys


def attrs(path):
    return {name:os.getxattr(path,name,follow_symlinks=False).hex()
            for name in sorted(os.listxattr(path,follow_symlinks=False))}


def restore_one(path, item):
    os.chown(path,item['uid'],item['gid'],follow_symlinks=False)
    if item['type'] != 'link':
        os.chmod(path,item['mode'])
    for name in os.listxattr(path,follow_symlinks=False):
        if name not in item['xattrs']:
            os.removexattr(path,name,follow_symlinks=False)
    for name,value in item['xattrs'].items():
        os.setxattr(path,name,bytes.fromhex(value),follow_symlinks=False)
    ns = item['mtime']*10**9+item['mtime_nsec']
    os.utime(path,ns=(ns,ns),follow_symlinks=False)


def restore(manifest, root):
    entries = json.loads(Path(manifest).read_text())['entries']
    for name,item in entries.items():
        restore_one(Path(root)/name,item)
    for name,item in entries.items():
        p = Path(root)/name
        s = p.lstat()
        assert (s.st_uid,s.st_gid,stat.S_IMODE(s.st_mode),s.st_mtime_ns,s.st_nlink) == (
            item['uid'],item['gid'],item['mode'],item['mtime']*10**9+item['mtime_nsec'],item['nlink']),name
        assert attrs(p) == item['xattrs'],name
    print(f'Exact source POSIX metadata restored and checked: {len(entries)} paths')


def replace(manifest, root, module):
    entries = json.loads(Path(manifest).read_text())['entries']
    name = 'lib/modules/msm_drm.ko'
    destination = Path(root)/name
    assert stat.S_ISREG(destination.lstat().st_mode)
    with destination.open('wb') as target,Path(module).open('rb') as source:
        while data := source.read(1024*1024):
            target.write(data)
    restore_one(destination,entries[name])
    print('Only existing msm_drm inode bytes replaced; original metadata restored')


def compare(before, after, extracted, output, packed_module):
    old = json.loads(Path(before).read_text())
    new = json.loads(Path(after).read_text())
    fields = ['type','mode','uid','gid','mtime','mtime_nsec','nlink','xattrs']
    assert set(old['entries']) == set(new['entries']), 'path set changed'
    sb_fields = ['size','magic','block_size','feature_compat','feature_incompat','uuid',
                 'volume_name_hex','compression_field','extra_devices','dirblkbits',
                 'xattr_prefix_count','packed_nid','inodes']
    for key in sb_fields:
        assert old['superblock'][key] == new['superblock'][key], ('filesystem profile',key)
    for report in (old,new):
        assert not report['superblock']['avb_footer']
        assert report['superblock']['tail_after_filesystem_all_zero']
    rows = []
    changed = []
    for name,a in old['entries'].items():
        b = new['entries'][name]
        for field in fields:
            assert a[field] == b[field], (name,field,a[field],b[field])
        assert a['xattrs'].get('security.selinux'), ('missing SELinux',name)
        if a['type'] == 'link':
            assert a['target'] == b['target'],name
        if name != 'lib/modules/msm_drm.ko':
            assert a['size'] == b['size'],name
            if a['type'] == 'file':
                assert a['sha256'] == b['sha256'],name
        if a['type'] == 'file':
            if a['sha256'] != b['sha256']:
                changed.append(name)
            rows.append({'path':name,'before_size':a['size'],'after_size':b['size'],
                         'before_sha256':a['sha256'],'after_sha256':b['sha256'],
                         'metadata':'MATCH','content':'CHANGED' if a['sha256']!=b['sha256'] else 'MATCH'})
        # Root extraction metadata can be filesystem-tool-specific; its actual
        # image attributes are nevertheless checked above by the raw reader.
        if name != '.':
            p = Path(extracted)/name
            s = p.lstat()
            assert (s.st_uid,s.st_gid,stat.S_IMODE(s.st_mode)) == (b['uid'],b['gid'],b['mode']),name
            assert attrs(p) == b['xattrs'],name
    assert changed == ['lib/modules/msm_drm.ko'],changed
    expected = hashlib.sha256(Path(packed_module).read_bytes()).hexdigest()
    assert new['entries']['lib/modules/msm_drm.ko']['sha256'] == expected
    out = Path(output)
    with out.with_suffix('.csv').open('w',newline='') as stream:
        writer = csv.DictWriter(stream,fieldnames=list(rows[0]))
        writer.writeheader();writer.writerows(rows)
    result = {'status':'PASS','paths':len(old['entries']),'regular_files':len(rows),
              'unchanged_files':len(rows)-1,'changed_content':changed,
              'metadata_all_paths':'MATCH including root, timestamps and SELinux bytes',
              'symlinks':sum(i['type']=='link' for i in new['entries'].values()),
              'filesystem_profile_fields':sb_fields,'source_superblock':old['superblock'],
              'candidate_superblock':new['superblock'],'packed_module_sha256':expected,
              'rows':rows,
              'installation_gate':'Source Stage44 identity and continuity confirmed by user; installer rechecks target/size/hash and existing AVB flags at installation; no device operations performed by agent.'}
    out.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:result[k] for k in ('status','paths','regular_files','unchanged_files','changed_content','symlinks')},indent=2))


if __name__ == '__main__':
    {'restore':restore,'replace':replace,'compare':compare}[sys.argv[1]](*sys.argv[2:])
