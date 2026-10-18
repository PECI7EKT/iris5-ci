#!/usr/bin/env python3
"""Verify all 24 imported external symbols using *new* authentic provider symvers."""
import csv, json, pathlib, sys
K = pathlib.Path("sources/modules")
OUT = pathlib.Path("ci-out")
providers = [
 "qcom/opensource/securemsm-kernel",
 "qcom/opensource/mm-drivers/msm_ext_display",
 "qcom/opensource/mmrm-driver",
 "oplus/kernel/boot/oplus_projectinfo",
 "oplus/kernel/boot/bootmode",
 "oplus/kernel/device_info/device_info",
 "oplus/kernel/touchpanel/touchpanel_notify",
]
found = {}
results = {}
for provider in providers:
    file = K / provider / "Module.symvers"
    if not file.is_file() or not file.stat().st_size:
        sys.exit(f"BLOCKED: fresh provider Module.symvers missing/empty: {file}")
    recs = 0
    for line in file.read_text().splitlines():
        cols = line.split("\t")
        if len(cols) != 5:
            sys.exit(f"BLOCKED: malformed provider symvers: {file}")
        crc, name = cols[0].lower(), cols[1]
        if name in found:
            sys.exit(f"BLOCKED: duplicate external export {name}")
        found[name] = {"crc": crc, "provider": provider,
                       "export_kind": cols[3], "namespace": cols[4]}
        recs += 1
    results[provider] = {"exports": recs}

required = {}
with pathlib.Path("ci/reference/symbol_comparison.csv").open(encoding="utf-8-sig", newline="") as f:
    for r in csv.DictReader(f):
        if r["kernel_symvers_status"] == "ABSENT":
            required[r["symbol"]] = r["reference_crc"].lower()
if len(required) != 24:
    sys.exit(f"BLOCKED: incorrect reference external count {len(required)}")
for sym, want in required.items():
    got = found.get(sym)
    if got is None or got["crc"] != want:
        sys.exit(f"BLOCKED: freshly built external CRC {sym}: expected {want}, got {got}")

payload = {"status":"PASS", "matched_external_imports":24, "provider_symvers":results,
           "exact_verified_symbols":{s:found[s] for s in sorted(required)}}
(OUT / "external_crc_check.json").write_text(json.dumps(payload, indent=2) + "\n")
print("NEW EXTERNAL PROVIDERS: 24 / 24 exact reference CRC MATCH")
