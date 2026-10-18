#!/usr/bin/env python3
"""Compare extracted EROFS metadata, content and xattrs across repackage.
Strict: any loss of metadata or changes outside msm_drm.ko block the candidate.
"""
import hashlib, json, os, pathlib, stat, sys
ROOT = pathlib.Path(sys.argv[1]); out = pathlib.Path(sys.argv[2]);

def sha(p):
    h = hashlib.sha256()
    with p.open('rb') as f:
        while chunk := f.read(1024 * 1024): h.update(chunk)
    return h.hexdigest()

def item(p):
    s = p.lstat()
    typ = ('link' if p.is_symlink() else 'dir' if p.is_dir() else 'file' if p.is_file() else 'other')
    if typ == 'other': raise ValueError(f'Unexpected inode type: {p}')
    attrs={}
    for key in sorted(os.listxattr(p, follow_symlinks=False)):
        attrs[key]=os.getxattr(p,key,follow_symlinks=False).hex()
    return dict(type=typ,mode=stat.S_IMODE(s.st_mode),uid=s.st_uid,gid=s.st_gid,
                xattrs=attrs, content=sha(p) if typ=='file' else os.readlink(p) if typ=='link' else None)

def manifest(root):
    entries={}
    for basedir, dirs, files in os.walk(root, topdown=True, followlinks=False):
        bp=pathlib.Path(basedir)
        for name in sorted(dirs+files):
            p=bp/name
            entries[p.relative_to(root).as_posix()]=item(p)
    return entries
m=manifest(ROOT)
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(m, indent=2,sort_keys=True)+'\n')
print(f'MANIFEST {out}: {len(m)} files/dirs')
if len(sys.argv)>3:
    a=json.loads(pathlib.Path(sys.argv[3]).read_text())
    if set(a)!=set(m): sys.exit('BLOCKED: EROFS file tree differs from original')
    special='lib/modules/msm_drm.ko'
    if special not in m:sys.exit('BLOCKED: no msm_drm.ko in image')
    for key in a:
        old,new=a[key].copy(),m[key].copy()
        if key==special: old.pop('content');new.pop('content')
        if old!=new: sys.exit('BLOCKED: mode/uid/gid/xattrs or unrelated file mismatch: '+key)
    print('MANIFEST MATCH: all file attributes and unchanged file bytes preserved')
