#!/usr/bin/env python3
"""Stage35: bounded, opt-in RDPTR event counter + VBLANK caller trace, NO behavior change."""
from pathlib import Path
import sys
if len(sys.argv)!=2: raise SystemExit("usage: apply.py <display-drivers-root>")
root=Path(sys.argv[1])
p=root/"msm/sde/sde_encoder_phys_cmd.c"
q=root/"msm/sde/sde_encoder.c"
s=p.read_text()
v=q.read_text()
if "IRIS35_" in s or "IRIS35_" in v: raise SystemExit("BLOCKED: Stage35 already present")
if "IRIS34_IRQ_WAIT_POST" not in v: raise SystemExit("BLOCKED: Stage34 prerequisite missing")
if "IRIS33_PULSE_BEGIN" not in (root/"msm/iris/iris5/dsi_iris5_lp.c").read_text():
    raise SystemExit("BLOCKED: Stage33 prerequisite missing")

def one(label, source, before, after):
    n=source.count(before)
    if n!=1: raise SystemExit(f"BLOCKED {label}: occurrences={n}")
    return source.replace(before, after, 1)

s=one("include",s,'#include "sde_encoder_phys.h"\n',
      '#include "sde_encoder_phys.h"\n#include <linux/moduleparam.h>\n')
s=one("option",s,'#define SDE_ENC_WR_PTR_START_TIMEOUT_US 20000\n',
'''#define SDE_ENC_WR_PTR_START_TIMEOUT_US 20000
/*
 * Stage35 diagnostics are OFF by default, never touch hardware, IRQ masks,
 * counters of the DRM protocol, or timeout handling.
 */
static bool iris35_vblank_diag;
module_param_named(iris35_vblank_diag, iris35_vblank_diag, bool, 0600);
MODULE_PARM_DESC(iris35_vblank_diag, "Iris5 RDPTR/VBLANK diagnostics only (default OFF)");
static atomic64_t iris35_rdptr_callback_count = ATOMIC64_INIT(0);
''')
def scope(label, a, b, changes):
    global s
    start=s.find(a)
    end=s.find(b,start+len(a))
    if start < 0 or end < 0 or s.find(a,start+1)>=0:
        raise SystemExit(f"BLOCKED: {label} bounds")
    sub=s[start:end]
    for name,old,new in changes:
        sub=one(label+"."+name,sub,old,new)
    s=s[:start]+sub+s[end:]

scope("cb","static void sde_encoder_phys_cmd_te_rd_ptr_irq(",
      "\nstatic void sde_encoder_phys_cmd_wr_ptr_irq(",[
  ("count",
   '''\tatomic_add_unless(&cmd_enc->pending_vblank_cnt, -1, 0);
\twake_up_all(&cmd_enc->pending_vblank_wq);''',
   '''\tif (READ_ONCE(iris35_vblank_diag))
        atomic64_inc(&iris35_rdptr_callback_count);
    atomic_add_unless(&cmd_enc->pending_vblank_cnt, -1, 0);
\twake_up_all(&cmd_enc->pending_vblank_wq);''')
])
scope("wait","static int sde_encoder_phys_cmd_wait_for_vblank(",
      "\nstatic void sde_encoder_phys_cmd_update_split_role(",[
  ("locals", '\tint rc = 0;\n',
   '''\tint rc = 0;
    u64 iris35_begin_ns = 0;
    s64 iris35_before = 0;
    bool iris35_do_trace = false;'''),
  ("enter",'''\tatomic_inc(&cmd_enc->pending_vblank_cnt);

\trc = sde_encoder_helper_wait_for_irq(phys_enc, INTR_IDX_RDPTR,
\t\t\t&wait_info);''',
   '''    iris35_do_trace = READ_ONCE(iris35_vblank_diag);
    if (iris35_do_trace) {
        iris35_begin_ns = ktime_get_ns();
        iris35_before = atomic64_read(&iris35_rdptr_callback_count);
        SDE_ERROR_CMDENC(cmd_enc,
            "IRIS35_WAIT_BEGIN irq=%d ref=%d pending=%d enc_state=%d timeout=%lld cb=%lld\\n",
            READ_ONCE(phys_enc->irq[INTR_IDX_RDPTR].irq_idx),
            atomic_read(&phys_enc->vblank_refcount),
            atomic_read(&cmd_enc->pending_vblank_cnt),
            phys_enc->enable_state,
            (long long)wait_info.timeout_ms,
            (long long)iris35_before);
    }
\tatomic_inc(&cmd_enc->pending_vblank_cnt);

\trc = sde_encoder_helper_wait_for_irq(phys_enc, INTR_IDX_RDPTR,
\t\t\t&wait_info);
    if (iris35_do_trace)
        SDE_ERROR_CMDENC(cmd_enc,
            "IRIS35_WAIT_END rc=%d elapsed_us=%llu irq=%d ref=%d pending=%d cb_delta=%lld\\n",
            rc, (unsigned long long)((ktime_get_ns()-iris35_begin_ns)/1000),
            READ_ONCE(phys_enc->irq[INTR_IDX_RDPTR].irq_idx),
            atomic_read(&phys_enc->vblank_refcount),
            atomic_read(&cmd_enc->pending_vblank_cnt),
            (long long)(atomic64_read(&iris35_rdptr_callback_count)-iris35_before));''')
])
scope("control","static int sde_encoder_phys_cmd_control_vblank_irq(",
      "\nvoid sde_encoder_phys_cmd_dynamic_irq_control(",[
  ("end",'''\tmutex_unlock(phys_enc->vblank_ctl_lock);
\tif (ret) {''',
   '''    if (READ_ONCE(iris35_vblank_diag) && ret)
        SDE_ERROR_CMDENC(cmd_enc,
            "IRIS35_VBLANK_REF_ERR enable=%d ret=%d ref=%d irq=%d\\n",
            enable, ret, atomic_read(&phys_enc->vblank_refcount),
            READ_ONCE(phys_enc->irq[INTR_IDX_RDPTR].irq_idx));
\tmutex_unlock(phys_enc->vblank_ctl_lock);
\tif (ret) {''')
])
scope("connect_te","static void sde_encoder_phys_cmd_connect_te(",
      "\nstatic int sde_encoder_phys_cmd_te_get_line_count(",[
  ("event",'\tSDE_EVT32(DRMID(phys_enc->parent), enable);\n',
   '''    if (READ_ONCE(iris35_vblank_diag))
        SDE_ERROR_CMDENC(to_sde_encoder_phys_cmd(phys_enc),
            "IRIS35_TE_CONNECT enable=%d has_intf_te=%d\\n",
            enable, phys_enc->has_intf_te);
\tSDE_EVT32(DRMID(phys_enc->parent), enable);
''')
])
v=one("caller",v,
'''            ret = fn_wait(phys);''',
'''            if (event == MSM_ENC_VBLANK && READ_ONCE(iris34_irq_diag))
                SDE_ERROR_ENC(sde_enc,
                    "IRIS35_VBLANK_CALL caller=%pS phys=%d\\n",
                    __builtin_return_address(0), i);
            ret = fn_wait(phys);''') if "            ret = fn_wait(phys);" in v else v
# Above uses spaces in some trees, tabs in others. Fail closed.
if "IRIS35_VBLANK_CALL" not in v:
    v=one("caller-tabs",v,'\t\t\tret = fn_wait(phys);',
'''            if (event == MSM_ENC_VBLANK && READ_ONCE(iris34_irq_diag))
                SDE_ERROR_ENC(sde_enc,
                    "IRIS35_VBLANK_CALL caller=%pS phys=%d\\n",
                    __builtin_return_address(0), i);
\t\t\tret = fn_wait(phys);''')
for m in ("IRIS35_WAIT_BEGIN","IRIS35_WAIT_END","IRIS35_VBLANK_REF_ERR","IRIS35_TE_CONNECT"):
    if s.count(m)!=1: raise SystemExit("BLOCKED missing marker "+m)
if v.count("IRIS35_VBLANK_CALL")!=1: raise SystemExit("BLOCKED missing caller")
p.write_text(s); q.write_text(v)
print("STAGE35 APPLY PASS: opt-in read-only RDPTR callback counters, vblank wait+caller telemetry")
