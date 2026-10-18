#!/usr/bin/env python3
"""Fail closed: verify downloaded stage17 foundation files and reference ABI."""
import csv, hashlib, json, os, pathlib, subprocess, sys

F = pathlib.Path("stage18-foundation")
K = pathlib.Path("sources/kernel/out")
REF = pathlib.Path("ci/reference")
OUT = pathlib.Path("ci-out")
OUT.mkdir(exist_ok=True)
EXPECTED = {
    "generated_kernel_Module.symvers": "25cd641cd235bb7d010a77a4c6592447186358247e26cf51f99370788f9bc05c",
    "generated_kernel.config": "d921ed3db4681f30371cfabc5b4665e113b317f94fc0d3dc5f45a49338703c5c",
}


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fp:
        for part in iter(lambda: fp.read(1024*1024), b""):
            h.update(part)
    return h.hexdigest()


for filename, digest in EXPECTED.items():
    actual = sha256(F / filename)
    if actual != digest:
        sys.exit(f"BLOCKED: foundation {filename} hash mismatch {actual} != {digest}")

if (F / "foundation_status.txt").read_text().find("739/739") < 0:
    sys.exit("BLOCKED: foundation build does not report 739/739")
if (F / "exit_status.txt").read_text().strip() != "0":
    sys.exit("BLOCKED: foundation build exit status != 0")

if sha256(K / "Module.symvers") != EXPECTED["generated_kernel_Module.symvers"]:
    sys.exit("BLOCKED: restored kernel symvers differs from successful stage17 build")
if sha256(K / ".config") != EXPECTED["generated_kernel.config"]:
    sys.exit("BLOCKED: restored config differs from successful stage17 build")

# Two host-dependent config flags are the *only* permitted differences from build#6.
cfg = (K / ".config").read_text()
orig = (REF / "original_Image.config").read_text()
allowed = {"CONFIG_CC_CAN_LINK=y", "CONFIG_UAPI_HEADER_TEST=y"}
normalized = "\n".join(x for x in cfg.splitlines() if x not in allowed) + "\n"
if normalized != orig:
    sys.exit("BLOCKED: restored configuration has unreviewed differences")

# Kernel symvers must contain every originally imported kernel export with exact CRC.
found = {}
for i, line in enumerate((K / "Module.symvers").read_text().splitlines(), 1):
    col = line.split("\t")
    if len(col) != 5 or col[1] in found:
        sys.exit(f"BLOCKED: malformed/duplicate kernel symvers row {i}")
    found[col[1]] = col[0].lower()
checked = 0
with (REF / "symbol_comparison.csv").open(encoding="utf-8-sig", newline="") as fp:
    for row in csv.DictReader(fp):
        if row["kernel_symvers_status"] == "MATCH":
            if found.get(row["symbol"]) != row["reference_crc"].lower():
                sys.exit(f"BLOCKED: kernel CRC mismatch {row['symbol']}")
            checked += 1
if checked != 739:
    sys.exit(f"BLOCKED: expected 739 kernel imports, got {checked}")

# inspect ELF with host readelf after zstd decode, without running it.
subprocess.run(["readelf", "-h", str(K / "vmlinux")], stdout=subprocess.DEVNULL, check=True)
sec = subprocess.check_output(["readelf", "-SW", str(K / "vmlinux")], text=True)
if ".BTF" not in sec:
    sys.exit("BLOCKED: restored vmlinux lacks BTF section")

result = {"foundation_run": 39088927882, "kernel_crc_matches": checked,
          "source_config": EXPECTED["generated_kernel.config"],
          "kernel_symvers": EXPECTED["generated_kernel_Module.symvers"],
          "vmlinux_sha256": sha256(K / "vmlinux"),
          "btf_present": True, "stage": "PREPARED_EXTERNAL_MODULE_BUILD"}
(OUT / "foundation_restored.json").write_text(json.dumps(result, indent=2) + "\n")
print("STAGE18 FOUNDATION RESTORE PASS: 739/739 kernel CRC + vmlinux BTF")
