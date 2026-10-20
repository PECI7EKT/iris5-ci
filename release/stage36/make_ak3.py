#!/usr/bin/env python3
"""Fail-closed stage36 vendor_dlkm_b ONLY OrangeFox/AK3 packaging from developer template.

No boot/DTBO/vendor_boot payloads or flashing operations are present. The only write
is an explicit dd to /dev/block/mapper/vendor_dlkm_b guarded by pre/post SHA256.
"""
import argparse, hashlib, os, pathlib, re, shutil, subprocess, zipfile

BASE_SHA="e2b9b423fbcf804e3f6fb4678441e1f0ddc7bee61fccab3d7c2da8e3c7c13237"
STAGE35_SHA="1f8583c5418f677fb5ec680cd9c9be3d3c7c76016575c2e667116c7627c2ca58"
IMAGE_BYTES=31768576

def sha(p):
    h=hashlib.sha256()
    with open(p,"rb") as f:
        for chunk in iter(lambda:f.read(2**20),b""):
            h.update(chunk)
    return h.hexdigest()

def mk_script(expected_from, expected_to, label):
    assert re.fullmatch("[0-9a-f]{64}",expected_from)
    assert re.fullmatch("[0-9a-f]{64}",expected_to)
    return """### AnyKernel3 - Iris5 %s, ONLY vendor_dlkm_b
properties() { '
kernel.string=Iris5 %s vendor_dlkm_b-only
do.devicecheck=1
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=RE5860
device.name2=senna
device.name3=RMX3706
device.name4=RMX3708
device.name5=RMX3709
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; }

# This script never modifies boot, dtbo, vendor_boot, recovery or vbmeta.
BLOCK=/dev/block/mapper/vendor_dlkm_b;
IS_SLOT_DEVICE=1;
PATCH_VBMETA_FLAG=0;
NO_VBMETA_PARTITION_PATCH=1;
. tools/ak3-core.sh;

# Explicitly constrain writes to the confirmed active _b slot.
# AK3 setup_ak computes SLOT in the sourced core; find_slot is unavailable in this shell.
[ "$SLOT" = "_b" ] || abort "BLOCKED: AK3 detected slot '$SLOT' (expected _b)"
PART=/dev/block/mapper/vendor_dlkm_b
[ -b "$PART" ] || abort "BLOCKED: vendor_dlkm_b block mapper is absent"
[ -f "$AKHOME/vendor_dlkm.img" ] || abort "BLOCKED: image absent"
[ "$(wc -c < "$AKHOME/vendor_dlkm.img")" = "31768576" ] || abort "BLOCKED: candidate image size incorrect"

EXPECTED_FROM=%s
EXPECTED_TO=%s
IMAGE_SHA="$(sha256sum "$AKHOME/vendor_dlkm.img" | cut -d ' ' -f1)"
[ "$IMAGE_SHA" = "$EXPECTED_TO" ] || abort "BLOCKED: embedded image hash mismatch"
CURRENT_SHA="$(sha256sum "$PART" | cut -d ' ' -f1)"
[ "$CURRENT_SHA" = "$EXPECTED_FROM" ] || abort "BLOCKED: unexpected existing vendor_dlkm_b hash"

ui_print " " "Iris5 %s - vendor_dlkm_b only"
ui_print "Verified current partition and embedded image SHA256"
dd if="$AKHOME/vendor_dlkm.img" of="$PART" bs=4096 || abort "BLOCKED: write failed"
sync
NEW_SHA="$(sha256sum "$PART" | cut -d ' ' -f1)"
[ "$NEW_SHA" = "$EXPECTED_TO" ] || abort "BLOCKED: post-write checksum mismatch. Restore backup!"
ui_print "Stage image installed: vendor_dlkm_b SHA256 verified"
## end install
""" % (label,label,expected_from,expected_to,label)

def build(base_path, img, sourcehash, targethash, label, out_path):
    script=mk_script(sourcehash,targethash,label)
    assert not re.search(r"(?m)^\s*(?:flash_generic|flash_boot|dump_boot|repack_ramdisk)\b", script)
    assert script.count('dd if="$AKHOME/vendor_dlkm.img" of="$PART"')==1
    with zipfile.ZipFile(base_path,"r") as src:
        names=src.namelist()
        assert len(names)==len(set(names))
        assert "META-INF/com/google/android/update-binary" in names
        assert "META-INF/com/google/android/updater-script" in names
        assert "tools/ak3-core.sh" in names
        assert "anykernel.sh" in names and "vendor_dlkm.img" in names
        with zipfile.ZipFile(out_path,"w",allowZip64=True) as dst:
            for item in src.infolist():
                if item.filename in ("anykernel.sh","vendor_dlkm.img","Image","dtbo.img","vendor_boot.img"):
                    continue
                # Reject unknown potentially active root payloads.
                if not (item.filename.startswith("META-INF/") or item.filename.startswith("tools/") or item.filename == "LICENSE"):
                    raise RuntimeError("unexpected template entry: "+item.filename)
                dst.writestr(item,src.read(item.filename))
            z=zipfile.ZipInfo("anykernel.sh",(2026,10,19,12,0,0))
            z.compress_type=zipfile.ZIP_DEFLATED
            z.external_attr=(0o100755<<16)
            dst.writestr(z,script.encode("utf-8"))
            zimg=zipfile.ZipInfo("vendor_dlkm.img",(2026,10,19,12,0,0))
            zimg.compress_type=zipfile.ZIP_DEFLATED
            zimg.external_attr=(0o100644<<16)
            dst.write(img,arcname="vendor_dlkm.img",compress_type=zipfile.ZIP_DEFLATED,compresslevel=6)
    with zipfile.ZipFile(out_path) as check:
        contents=set(check.namelist())
        assert "Image" not in contents and "dtbo.img" not in contents and "vendor_boot.img" not in contents
        assert not any(n.startswith("ksu/") for n in contents)
        assert set(["anykernel.sh","vendor_dlkm.img"]).issubset(contents)
        assert len(check.read("vendor_dlkm.img")) == IMAGE_BYTES
        assert hashlib.sha256(check.read("vendor_dlkm.img")).hexdigest()==targethash
        restored=check.read("anykernel.sh").decode()
        assert restored==script
    subprocess.run(["sh","-n"],input=script,text=True,check=True)
    print("AK3_AUDIT_OK",label,sha(out_path),out_path)
    print("target_sha",targethash,"source_sha",sourcehash)
    return out_path

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--template",required=True)
    ap.add_argument("--stage35-image",required=True)
    ap.add_argument("--stage36-image",required=True)
    ap.add_argument("--stage36-sha",required=True)
    ap.add_argument("--outdir",default="stage36-packages")
    a=ap.parse_args()
    base=pathlib.Path(a.template)
    old=pathlib.Path(a.stage35_image)
    new=pathlib.Path(a.stage36_image)
    assert sha(base)==BASE_SHA, "original developer AK3 mismatch"
    assert old.stat().st_size==new.stat().st_size==IMAGE_BYTES
    assert sha(old)==STAGE35_SHA, "installed Stage35 source image SHA mismatch"
    stage36_sha=sha(new)
    assert re.fullmatch(r"[0-9a-f]{64}",a.stage36_sha)
    assert stage36_sha==a.stage36_sha, "Stage36 image does not match pinned digest"
    assert stage36_sha!=STAGE35_SHA
    out=pathlib.Path(a.outdir)
    out.mkdir(parents=True,exist_ok=True)
    build(base,new,STAGE35_SHA,stage36_sha,"STAGE36-VBLANK-GUARD",
          out/"Iris5-Stage36-VBLANK-GUARD-OrangeFox-AK3.zip")
    build(base,old,stage36_sha,STAGE35_SHA,"ROLLBACK-STAGE35",
          out/"Iris5-Stage35-ROLLBACK-from-Stage36-OrangeFox-AK3.zip")
    (out/"images.sha256").write_text(
         stage36_sha+"  STAGE36 vendor_dlkm_b image\n"+
         STAGE35_SHA+"  STAGE35 installed rollback image\n")
    print("STAGE36 INSTALL+STAGE35 ROLLBACK ZIP VERIFIED. Not runtime tested.")

if __name__=="__main__":
    main()
