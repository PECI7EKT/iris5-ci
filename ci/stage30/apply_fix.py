#!/usr/bin/env python3
"""Stage30: bound CM FTC requests to real Senna Iris5 DTSI options.

The three timing command tables support IRIS_IP_CM options 0x10..0x14.
Stock service requests FTC level 5 -> unsupported 0x15, logging FATAL ERROR.
Map the one known out-of-range level 5 to 4, explicitly and with a warning.
Do not fabricate new panel data, change the Iris5 init sequence, or touch ABYP/ESD.
"""
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: apply_fix.py <display-drivers-root>")
path=Path(sys.argv[1])/"msm/iris/iris5/dsi_iris5_pq.c"
src=path.read_text()
before="""	iris_init_ipopt_ip(popt,  IP_OPT_MAX);
	locallevel = 0x10 | (u8)level;
	iris_capture_disable_pq(popt, &skiplast);

	len = iris_update_ip_opt(
			popt, IP_OPT_MAX, IRIS_IP_CM, locallevel, skiplast);"""
after="""	iris_init_ipopt_ip(popt,  IP_OPT_MAX);

	/*
	 * Stage30: Senna's three Iris5 DTSI timing lists define CM FTC
	 * options 0x10..0x14, not 0x15. The service requests level 5.
	 * Alias only level 5 to the highest existing calibrated level 4.
	 * Do not silently wrap arbitrary uint32_t values to uint8_t.
	 */
	if (level > 4) {
		if (level != 5) {
			IRIS_LOGE("IRIS30_FTC_REJECT unsupported level=%u", level);
			return;
		}
		IRIS_LOGW("IRIS30_FTC_FALLBACK requested=5 applied=4");
		level = 4;
	}
	locallevel = 0x10 | (u8)level;
	if (!iris_find_ip_opt(IRIS_IP_CM, locallevel)) {
		IRIS_LOGE("IRIS30_FTC_MISSING available option=0x%x",
			locallevel);
		return;
	}

	iris_capture_disable_pq(popt, &skiplast);

	len = iris_update_ip_opt(
			popt, IP_OPT_MAX, IRIS_IP_CM, locallevel, skiplast);"""
num=src.count(before)
if num!=1:
    raise SystemExit(f"BLOCKED: FTC setter anchor expected once; got {num}")
src=src.replace(before,after,1)
if src.count("IRIS30_FTC_FALLBACK")!=1:
    raise SystemExit("BLOCKED: stage30 fallback not unique")
path.write_text(src)
print("STAGE30 FTC FIX APPLIED: request level5 uses existing DTSI level4; ABYP/ESD/DCS untouched")
