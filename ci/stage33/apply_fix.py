#!/usr/bin/env python3
"""Stage33 strictly opt-in post-reset host DSI pulse. Apply AFTER Stage29."""
from pathlib import Path
import sys
if len(sys.argv)!=2: raise SystemExit("usage: apply_fix.py <display-drivers-root>")
p=Path(sys.argv[1])/"msm/iris/iris5/dsi_iris5_lp.c"
s=p.read_text()
if "IRIS33_PULSE" in s or "IRIS27_EXIT_ATTEMPT" not in s or "IRIS23_DPHY" not in s:
    raise SystemExit("BLOCKED: expected exact Stage29 source")
def put(name,a,b):
    global s
    n=s.count(a)
    if n!=1: raise SystemExit(f"BLOCKED {name} occurrences={n}")
    s=s.replace(a,b,1)
put("headers",'#include "dsi_iris5_frc.h"\n','#include "dsi_iris5_frc.h"\n#include "dsi_display.h"\n#include "dsi_clk.h"\n#include <linux/err.h>\n#include <linux/moduleparam.h>\n')
put("parameter","static bool iris_bsram_power; /* BSRAM domain power status */",'''static bool iris_bsram_power; /* BSRAM domain power status */
/* Experimental Stage33, disabled until intentionally enabled by root. */
static bool iris33_postreset_pulse;
module_param_named(iris33_postreset_pulse, iris33_postreset_pulse, bool, 0600);
MODULE_PARM_DESC(iris33_postreset_pulse, "Stage33 test post-reset DSI pulse (default OFF)");''')
put("rename plus exit","static bool _iris_plus_cmd_abyp_exit(int mode)\n{",'''static bool _iris_plus_cmd_abyp_exit_impl(int mode, struct dsi_display *display)
{''')
helper='''/*
 * Stage33 prototype: reproduces only the normal DSI manager ON->OFF
 * phase observed between Iris reset and ready-bit change. No ESD calls,
 * MMIO, forced clock changes, packet injection or new delays.
 *
 * Since dsi_clk_req_state increments its client references before
 * switching hardware, an attempted ON must be paired with OFF even
 * when ON returns an error. Hardware rollback still isn't guaranteed.
 */
static bool iris33_pulse_dsi(struct dsi_display *display,
                             struct iris_cfg *pcfg, int attempt)
{
    int on_rc, off_rc;
    if (!display || !pcfg || !pcfg->panel ||
        display->panel != pcfg->panel ||
        !display->dsi_clk_handle || IS_ERR(display->dsi_clk_handle) ||
        !display->panel->panel_initialized ||
        display->panel->panel_mode != DSI_OP_CMD_MODE ||
        atomic_read(&display->panel->esd_recovery_pending) ||
        display->trusted_vm_env) {
        IRIS_LOGE("IRIS33_PULSE_BLOCKED n=%d", attempt);
        return false;
    }

    IRIS_LOGI("IRIS33_PULSE_BEGIN n=%d", attempt);
    on_rc = dsi_display_clk_ctrl(display->dsi_clk_handle,
                                  DSI_ALL_CLKS, DSI_CLK_ON);
    off_rc = dsi_display_clk_ctrl(display->dsi_clk_handle,
                                   DSI_ALL_CLKS, DSI_CLK_OFF);
    IRIS_LOGI("IRIS33_PULSE_END n=%d on=%d off=%d",
              attempt, on_rc, off_rc);
    if (on_rc || off_rc) {
        IRIS_LOGE("IRIS33_PULSE_UNSAFE n=%d on=%d off=%d",
                  attempt, on_rc, off_rc);
        return false;
    }
    return true;
}

'''
put("add helper","static bool _iris_plus_cmd_abyp_exit_impl(int mode, struct dsi_display *display)\n{",helper+"static bool _iris_plus_cmd_abyp_exit_impl(int mode, struct dsi_display *display)\n{")
needle='''\tIRIS_LOGI("IRIS27_EXIT_ATTEMPT n=%d prev=%d current=%d init=%d i2c=%d",
\t\t4 - toler_cnt, prev_mode, pcfg->abypss_ctrl.abypass_mode,
\t\tpcfg->iris_initialized, pcfg->iris_i2c_switch);
\tabyp_status_gpio = iris_exit_abyp(false);'''
repl='''\tIRIS_LOGI("IRIS27_EXIT_ATTEMPT n=%d prev=%d current=%d init=%d i2c=%d",
\t\t4 - toler_cnt, prev_mode, pcfg->abypss_ctrl.abypass_mode,
\t\tpcfg->iris_initialized, pcfg->iris_i2c_switch);
\tif (display && iris33_postreset_pulse &&
\t    pcfg->iris_i2c_switch && prev_mode == ABP_SLEEP_MODE) {
\t\tif (!iris33_pulse_dsi(display, pcfg, 4 - toler_cnt))
\t\t\treturn false; /* do not send SYS5 when clock state uncertain */
\t}
\tabyp_status_gpio = iris_exit_abyp(false);'''
put("pulse placement",needle,repl)
put("compatibility wrapper","static bool _iris_cmd_abyp_exit(int mode)\n{",'''/* Preserve existing abyp_ops bool (*)(int) contract for all callers. */
static bool _iris_plus_cmd_abyp_exit(int mode)
{
    return _iris_plus_cmd_abyp_exit_impl(mode, NULL);
}

static bool _iris_cmd_abyp_exit(int mode)
{''')
put("opt-in call routing",'''\t\tif (pcfg->rx_mode == DSI_OP_CMD_MODE) {
\t\t\tpt_mode = pcfg->abyp_ops.abyp_exit(mode & 0x3);
\t\t} else {''','''\t\tif (pcfg->rx_mode == DSI_OP_CMD_MODE) {
\t\t\tif (iris33_postreset_pulse && pcfg->iris_i2c_switch &&
\t\t\t    pcfg->chip_id == IRIS_CHIP_VER_1)
\t\t\t\tpt_mode = _iris_plus_cmd_abyp_exit_impl(mode & 0x3,
\t\t\t\t                                           display);
\t\t\telse
\t\t\t\tpt_mode = pcfg->abyp_ops.abyp_exit(mode & 0x3);
\t\t} else {''')
if s.count("IRIS33_PULSE_BEGIN")!=1: raise SystemExit("BLOCKED: invalid Stage33 markers")
p.write_text(s)
print("STAGE33 APPLY PASS, opt-in default OFF, only lp.c modified")
