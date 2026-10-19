#!/usr/bin/env python3
"""Stage29: use checked Iris I2C for PT DCS response status/data registers.

Based on pinned Stage28 source. Preserves original DCS request, ESD criteria,
GPIO, DPHY, PT mode switch and display timings. No silent DSI fallback.
"""
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: apply_fix.py <display-drivers-root>")
root=Path(sys.argv[1])
p=root/"msm/iris/iris5/dsi_iris5_lightup_ocp.c"
s=p.read_text()
def replace(what,a,b,n=1):
    global s
    m=s.count(a)
    if m != n:
        raise SystemExit(f"BLOCKED stage29 drift {what}: expected {n}, got {m}")
    s=s.replace(a,b,n)
replace("I2C prototype include",
        '#include "dsi_iris5_log.h"',
        '#include "dsi_iris5_log.h"\n#include "dsi_iris5_i2c.h"')
helper="""/*
 * Stage29: the legacy iris_ocp_read() API only returns a u32, silently
 * collapsing DSI read errors to 0. In particular, this makes a broken DSI
 * OCP read indistinguishable from IRIS_TX_INTSTAT_RAW == 0, and yields a
 * false DCS timeout. The I2C address/read convention is identical to the
 * already exercised _iris_dphy_itf_check() path. Read ONLY the PT response
 * status/data registers here. Never substitute a zero on transport error.
 */
static int _iris_pt_checked_read(u32 addr, u32 *value)
{
    u32 v = addr;
    int rc;

    if (!value)
        return -EINVAL;

    rc = iris_i2c_conver_ocp_read(&v, 1, false);
    if (rc) {
        IRIS_LOGE("IRIS29_PT_RX_I2C_FAIL addr=0x%08x rc=%d", addr, rc);
        return rc < 0 ? rc : -EIO;
    }

    *value = v;
    return 0;
}

"""
replace("insert checked I2C read helper", "static int _iris_pt_read(struct dsi_panel_cmd_set *cmdset)\n{",
    helper+"static int _iris_pt_read(struct dsi_panel_cmd_set *cmdset)\n{")
replace("read status from confirmed I2C path",
        "\t\tintstat = iris_ocp_read(IRIS_TX_INTSTAT_RAW, cmdset->state);",
        """        rc = _iris_pt_checked_read(IRIS_TX_INTSTAT_RAW, &intstat);
        if (rc)
            return rc;""")
replace("read PT response packet data with transport check",
        "\n\tval.pld32 = iris_ocp_read(address, cmdset->state);",
        """\n    rc = _iris_pt_checked_read(address, &val.pld32);
    if (rc)
        return rc;""")
replace("read short response continuation",
        "\t\t\tval.pld32 = iris_ocp_read(address, cmdset->state);",
        """            rc = _iris_pt_checked_read(address, &val.pld32);
            if (rc)
                return rc;""")
replace("read long response data continuation",
        "\t\t\tval.pld32 = iris_ocp_read(address, DSI_CMD_SET_STATE_HS);",
        """            rc = _iris_pt_checked_read(address, &val.pld32);
            if (rc)
                return rc;""")
replace("checked read response diagnostic",
        'IRIS_LOGI("IRIS24_RXDATA addr=0x%08x val=0x%08x first=0x%02x requested=%u state=%d",',
        'IRIS_LOGI("IRIS24_RXDATA addr=0x%08x val=0x%08x first=0x%02x requested=%u state=%d",')
p.write_text(s)
print("STAGE29 SAFE PT-RX I2C TRANSPORT FIX APPLIED; original ESD and DCS request unchanged")
