#!/usr/bin/env python3
"""Stage38: read-only Iris ABYP GPIO/cache sysfs sample + opt-in transition records.
Based on Stage36. Does not change mode selection, IRQ handling, resets, clocks, or retries.
"""
from pathlib import Path
import sys
if len(sys.argv) != 2:
    raise SystemExit("usage: apply.py <display-drivers-root>")
r=Path(sys.argv[1]); p=r/"msm/iris/iris5/dsi_iris5_lp.c"; q=r/"msm/iris/iris5/dsi_iris5_ioctl.c"
s=p.read_text(); t=q.read_text()
if "iris38_hw_state" in s or "IRIS38_" in t: raise SystemExit("BLOCKED: Stage38 already applied")
if "IRIS33_PULSE_BEGIN" not in s or "IRIS36_VBLANK_NOT_ARMED" not in (r/"msm/sde/sde_encoder_phys_cmd.c").read_text():
    raise SystemExit("BLOCKED: exact Stage33+Stage36 prerequisite missing")

def one(label,a,old,new):
    n=a.count(old)
    if n!=1: raise SystemExit(f"BLOCKED {label}: expected one anchor, got {n}")
    return a.replace(old,new,1)

s=one("include",s,"#include <linux/moduleparam.h>\n",
  "#include <linux/moduleparam.h>\n#include <linux/mm.h>\n")
anchor='MODULE_PARM_DESC(iris33_postreset_pulse, "Stage33 test post-reset DSI pulse (default OFF)");'
add=r'''
/* Stage38 is READ-ONLY. The sysfs getter performs an on-demand GPIO sample.
 * Do not interpret GPIO while the panel is uninitialized/off. A trylock
 * avoids racing operations holding panel_lock; a busy sample is discarded.
 * No state mutation, no mode-switch, no active probing of the DSI bus.
 */
bool iris38_transition_diag;
module_param_named(iris38_transition_diag, iris38_transition_diag, bool, 0600);
MODULE_PARM_DESC(iris38_transition_diag,
                 "opt-in ABYP mode-request tracing, no behavior change (default OFF)");

static int iris38_hw_state_get(char *buf, const struct kernel_param *kp)
{
    struct iris_cfg *pcfg = iris_get_cfg();
    int gpio = -1, cached = -1, pending = -1, initialized = -1;
    int panel_on = 0, divergent = -1;

    if (!pcfg || !pcfg->panel || pcfg->valid < PARAM_PARSED)
        return scnprintf(buf, PAGE_SIZE,
                         "status=not_ready gpio=-1 cache=-1 divergent=-1\n");

    if (!mutex_trylock(&pcfg->panel->panel_lock))
        return scnprintf(buf, PAGE_SIZE,
                         "status=busy gpio=-1 cache=-1 divergent=-1\n");

    cached = pcfg->abypss_ctrl.abypass_mode;
    pending = pcfg->abypss_ctrl.pending_mode;
    initialized = pcfg->iris_initialized ? 1 : 0;
    panel_on = pcfg->panel->panel_initialized ? 1 : 0;
    if (panel_on) {
        gpio = iris_check_abyp_ready(); /* reads REAL GPIO, not GET56 */
        if (gpio == 0 || gpio == 1)
            divergent = (gpio == 0) ? (cached != PASS_THROUGH_MODE) :
                                       (cached == PASS_THROUGH_MODE);
    }
    mutex_unlock(&pcfg->panel->panel_lock);

    return scnprintf(buf, PAGE_SIZE,
        "status=%s gpio=%d cache=%d divergent=%d pending=%d iris_initialized=%d panel_initialized=%d\n",
        panel_on ? "sample" : "panel_off", gpio, cached, divergent,
        pending, initialized, panel_on);
}
static const struct kernel_param_ops iris38_hw_state_ops = {
    .get = iris38_hw_state_get,
};
module_param_cb(iris38_hw_state, &iris38_hw_state_ops, NULL, 0444);
MODULE_PARM_DESC(iris38_hw_state,
                 "read-only, on-demand hardware ABYP GPIO + cached mode snapshot");
'''
s=one("sysfs_param",s,anchor,anchor+"\n"+add)
target='''\tbool pt_mode = iris_is_pt_mode(pcfg->panel);

\tif (!pcfg->lp_ctrl.abyp_enable) {'''
replacement='''\tbool pt_mode = iris_is_pt_mode(pcfg->panel);

    if (READ_ONCE(iris38_transition_diag))
        IRIS_LOGI("IRIS38_ABYP_REQUEST requested=%d cached=%d cached_pt=%d pending=%d initialized=%d",
                  dest_mode, prev_mode, pt_mode, pending, pcfg->iris_initialized);
\tif (!pcfg->lp_ctrl.abyp_enable) {'''
s=one("transition_entry",s,target,replacement)
target='''\treturn pt_mode;
}

void iris_abyp_lp(int mode)'''
replacement='''    if (READ_ONCE(iris38_transition_diag))
        IRIS_LOGI("IRIS38_ABYP_RESULT requested=%d cached=%d ret_pt=%d",
                  dest_mode, pcfg->abypss_ctrl.abypass_mode, pt_mode);
\treturn pt_mode;
}

void iris_abyp_lp(int mode)'''
s=one("transition_result",s,target,replacement)

t=one("ioctl_extern",t,"void iris_plus_configure_abyp(int value)\n{",
      "extern bool iris38_transition_diag;\n\nvoid iris_plus_configure_abyp(int value)\n{")
t=one("cache_skip",t,'''\
\tif (mode == pcfg->abypss_ctrl.abypass_mode) {
\t\tIRIS_LOGI("%s Same bypass mode: %d", __func__, mode);
\t\treturn;
\t}''',
'''\
\tif (mode == pcfg->abypss_ctrl.abypass_mode) {
        if (READ_ONCE(iris38_transition_diag))
            IRIS_LOGI("IRIS38_CACHE_SKIP requested=%d cached=%d",
                      mode, pcfg->abypss_ctrl.abypass_mode);
\t\tIRIS_LOGI("%s Same bypass mode: %d", __func__, mode);
\t\treturn;
\t}''')
for expected in ("static int iris38_hw_state_get", "module_param_cb(iris38_hw_state", "IRIS38_ABYP_REQUEST", "IRIS38_ABYP_RESULT"):
    if s.count(expected)!=1: raise SystemExit("BLOCKED: missing lp marker "+expected)
if t.count("IRIS38_CACHE_SKIP")!=1: raise SystemExit("BLOCKED: missing ioctl marker")
p.write_text(s); q.write_text(t)
print("STAGE38 APPLY PASS: read-only locked GPIO+cache snapshot and opt-in request diagnostics")
