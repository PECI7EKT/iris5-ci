#!/usr/bin/env python3
"""Compare pristine module import ABI and compiled features; refuse false PASS."""
import csv, json, pathlib, re, subprocess, sys
from elftools.elf.elffile import ELFFile

mod = pathlib.Path(sys.argv[1])
out = pathlib.Path("ci-out")
with mod.open("rb") as f:
    elf = ELFFile(f)
    if elf.header["e_machine"] != "EM_AARCH64" or elf.elfclass != 64:
        sys.exit("BLOCKED: compiled output is not ARM64 ELF64")
    sections = {x.name for x in elf.iter_sections()}
    if ".BTF" not in sections:
        sys.exit("BLOCKED: compiled Display module missing .BTF")
    versions = elf.get_section_by_name("__versions")
    if versions is None:
        sys.exit("BLOCKED: compiled module missing __versions")
    data = versions.data()
    if len(data) % 64:
        sys.exit("BLOCKED: invalid modversion entry size")
    actual = {}
    for n in range(0, len(data), 64):
        crc = int.from_bytes(data[n:n+8], "little") & 0xffffffff
        name = data[n+8:n+64].split(b"\0", 1)[0].decode("ascii")
        if name in actual:
            sys.exit(f"BLOCKED: duplicate module import {name}")
        actual[name] = f"0x{crc:08x}"
    symtab = elf.get_section_by_name(".symtab")
    kcfi = sum(1 for s in symtab.iter_symbols() if s.name.startswith("__kcfi_")) if symtab else 0

expected = {}
with pathlib.Path("ci/reference/symbol_comparison.csv").open(encoding="utf-8-sig", newline="") as f:
    for row in csv.DictReader(f):
        expected[row["symbol"]] = row["reference_crc"].lower()
missing = sorted(set(expected) - set(actual))
extra = sorted(set(actual) - set(expected))
mismatch = {k:{"expected":v,"rebuilt":actual[k]}
            for k,v in expected.items() if k in actual and v != actual[k]}
vermagic = subprocess.check_output(["modinfo", "-F", "vermagic", str(mod)], text=True).strip()
report={"modpath":str(mod),"vermagic":vermagic,"btf_present":True,"kcfi_symbols":kcfi,
        "reference_imports":len(expected),"rebuilt_imports":len(actual),
        "missing_imports":missing,"extra_imports":extra,"crc_mismatch":mismatch}
(out / "baseline_abi.json").write_text(json.dumps(report,indent=2)+"\n")
if not vermagic.startswith("6.6.139-gki+ ") or "modversions" not in vermagic:
    sys.exit(f"BLOCKED: baseline vermagic differs: {vermagic}")
if kcfi < 1:
    sys.exit("BLOCKED: rebuilt Display module has no KCFI symbols")
if missing or extra or mismatch or len(actual) != 763:
    sys.exit(f"BLOCKED: baseline import ABI delta: missing={len(missing)} extra={len(extra)} crc_mismatch={len(mismatch)}")
print("UNMODIFIED DISPLAY BASELINE PASS: 763/763 import CRC + ARM64 + BTF + KCFI + vermagic")
