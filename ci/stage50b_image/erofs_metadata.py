#!/usr/bin/env python3
"""Read EROFS metadata directly; verify decompressed bytes from a separate fsck.

Format source: erofs-utils 51b5939b5f783221310d25146e6a2019ba8129b6,
include/erofs_fs.h. No inode offsets are inferred from extracted Windows files.
Only known layouts/features are accepted; unknown formats fail closed.
"""
from pathlib import Path
import hashlib
import json
import stat
import struct
import sys
import uuid

PREFIX = {1:'user.',2:'system.posix_acl_access',3:'system.posix_acl_default',
          4:'trusted.',5:'lustre.',6:'security.'}


class Erofs:
    def __init__(self, path):
        self.path = Path(path)
        self.data = self.path.read_bytes()
        sb = self.data[1024:1152]
        magic, checksum, compat, bits, ext, root = struct.unpack_from('<IIIBBH',sb)
        assert magic == 0xe0f5e1e2, 'not raw EROFS'
        self.block = 1 << bits
        inos, build_time, nsec, blocks, self.meta, self.xattr = struct.unpack_from('<QQIIII',sb,16)
        incompat = struct.unpack_from('<I',sb,80)[0]
        self.info = {'image':str(self.path),'size':len(self.data),
                     'sha256':hashlib.sha256(self.data).hexdigest(),
                     'magic':hex(magic),'checksum':hex(checksum),'feature_compat':compat,
                     'feature_incompat':incompat,'block_size':self.block,'superblock_extslots':ext,
                     'root_nid':root,'inodes':inos,'build_time':build_time,'build_time_nsec':nsec,
                     'blocks':blocks,'filesystem_bytes':blocks*self.block,'meta_blkaddr':self.meta,
                     'xattr_blkaddr':self.xattr,'uuid':str(uuid.UUID(bytes=sb[48:64])),
                     'volume_name_hex':sb[64:80].hex(),'compression_field':struct.unpack_from('<H',sb,84)[0],
                     'extra_devices':struct.unpack_from('<H',sb,86)[0],
                     'dirblkbits':sb[90],'xattr_prefix_count':sb[91],
                     'packed_nid':struct.unpack_from('<Q',sb,96)[0],
                     'avb_footer':self.data[-64:-60] == b'AVBf',
                     'tail_after_filesystem_bytes':len(self.data)-blocks*self.block,
                     'tail_after_filesystem_all_zero':not any(self.data[blocks*self.block:])}
        assert self.info['extra_devices'] == 0, 'multi-device unsupported'
        assert self.info['xattr_prefix_count'] == 0, 'long xattr prefix needs explicit support'
        assert self.info['packed_nid'] == 0, 'packed fragment inode needs explicit support'
        assert len(self.data) >= blocks*self.block

    def entry(self, offset):
        nlen, index, vlen = struct.unpack_from('<BBH',self.data,offset)
        assert index in PREFIX, f'unknown xattr index {index}'
        name = PREFIX[index]+self.data[offset+4:offset+4+nlen].decode()
        value = self.data[offset+4+nlen:offset+4+nlen+vlen]
        return name, value.hex(), (4+nlen+vlen+3)&~3

    def inode(self, nid):
        off = self.meta*self.block+nid*32
        fmt, count, mode = struct.unpack_from('<HHH',self.data,off)
        assert fmt & ~15 == 0, 'unknown inode format bits'
        extended = fmt & 1
        size = struct.unpack_from('<Q' if extended else '<I',self.data,off+8)[0]
        union = struct.unpack_from('<I',self.data,off+16)[0]
        if extended:
            uid,gid,mtime,nsec,nlink = struct.unpack_from('<IIQII',self.data,off+24)
        else:
            uid,gid = struct.unpack_from('<HH',self.data,off+24)
            mtime,nsec,nlink = self.info['build_time'],self.info['build_time_nsec'],struct.unpack_from('<H',self.data,off+6)[0]
        isize = 64 if extended else 32
        xsize = 12+(count-1)*4 if count else 0
        attrs = {}
        if count:
            begin = off+isize
            shared = self.data[begin+4]
            pos = begin+12
            assert pos+shared*4 <= begin+xsize
            for number in struct.unpack_from('<'+str(shared)+'I',self.data,pos) if shared else []:
                name,value,unused = self.entry(self.xattr*self.block+number*4)
                assert name not in attrs
                attrs[name] = value
            pos += shared*4
            while pos < begin+xsize:
                assert begin+xsize-pos >= 4
                name,value,length = self.entry(pos)
                assert pos+length <= begin+xsize
                assert name not in attrs
                attrs[name] = value
                pos += length
        kind = 'dir' if stat.S_ISDIR(mode) else 'file' if stat.S_ISREG(mode) else 'link' if stat.S_ISLNK(mode) else 'other'
        assert kind != 'other', 'unsupported special inode'
        return {'nid':nid,'inode_offset':off,'inode_size':isize,'xattr_size':xsize,
                'format':fmt,'data_layout':(fmt>>1)&7,'mode':stat.S_IMODE(mode),'type':kind,
                'size':size,'uid':uid,'gid':gid,'mtime':mtime,'mtime_nsec':nsec,'nlink':nlink,
                'raw_blkaddr':union,'xattrs':dict(sorted(attrs.items()))}

    def flat_data(self, inode):
        size, layout = inode['size'],inode['data_layout']
        assert layout in (0,2), f'unsupported non-flat directory/link layout {layout}'
        start = inode['raw_blkaddr']*self.block
        if layout == 0:
            return self.data[start:start+size]
        full = size//self.block*self.block
        tail = inode['inode_offset']+inode['inode_size']+inode['xattr_size']
        return self.data[start:start+full]+self.data[tail:tail+size-full]

    def walk(self):
        result = {}
        def descend(path,nid,parents):
            assert nid not in parents, 'directory cycle'
            item = self.inode(nid)
            if item['type'] == 'link':
                item['target'] = self.flat_data(item).decode()
            result[path] = item
            if item['type'] != 'dir':
                return
            data = self.flat_data(item)
            assert len(data) == item['size']
            for start in range(0,len(data),self.block):
                block = data[start:start+self.block]
                first_name = struct.unpack_from('<H',block,8)[0]
                assert first_name%12 == 0 and first_name >= 12 and first_name <= len(block)
                count = first_name//12
                records = [struct.unpack_from('<QHBB',block,i*12) for i in range(count)]
                for i,(child,offset,typ,reserved) in enumerate(records):
                    end = records[i+1][1] if i+1<count else len(block)
                    assert first_name <= offset < end <= len(block)
                    name = block[offset:end].split(b'\0',1)[0].decode()
                    if name in ('.','..'):
                        continue
                    assert name and '/' not in name
                    child_path = name if path=='.' else path+'/'+name
                    assert child_path not in result
                    descend(child_path,child,parents|{nid})
        descend('.',self.info['root_nid'],set())
        return result


def main(image, output, extracted=None):
    fs = Erofs(image)
    entries = fs.walk()
    if extracted:
        root = Path(extracted)
        for path,item in entries.items():
            if item['type']=='file':
                file = root/path
                assert file.is_file(),path
                assert file.stat().st_size==item['size'],path
                item['sha256'] = hashlib.sha256(file.read_bytes()).hexdigest()
    result = {'superblock':fs.info,'entry_count':len(entries),'entries':entries}
    Path(output).write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({'superblock':fs.info,'entries':len(entries),
                      'types':{typ:sum(i['type']==typ for i in entries.values()) for typ in ['dir','file','link']},
                      'labels':sorted({bytes.fromhex(i['xattrs'].get('security.selinux','')).rstrip(b'\0').decode() for i in entries.values()})},indent=2))


if __name__ == '__main__':
    main(*sys.argv[1:])
