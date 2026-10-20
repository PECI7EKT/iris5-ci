#!/usr/bin/env python3
"""Stage34 read-only IRQ lifecycle diagnostics; apply AFTER exact Stage33."""
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit('usage: apply_irq_diag.py <display-drivers-root>')
p = Path(sys.argv[1]) / 'msm/sde/sde_encoder.c'
s = p.read_text()
if 'IRIS34_IRQ_' in s or 'IRIS33_PULSE_' not in (Path(sys.argv[1])/'msm/iris/iris5/dsi_iris5_lp.c').read_text():
    raise SystemExit('BLOCKED: expected uninstrumented source with Stage33 applied')

def replace_once(label, needle, repl):
    global s
    count = s.count(needle)
    if count != 1:
        raise SystemExit(f'BLOCKED: Stage34 {label} anchor count {count} (expected 1)')
    s = s.replace(needle, repl, 1)

replace_once('include', '#include <linux/sde_rsc.h>\n',
             '#include <linux/sde_rsc.h>\n#include <linux/moduleparam.h>\n')
replace_once('parameter', '#define EVT_TIME_OUT_SPLIT 2\n',
'''#define EVT_TIME_OUT_SPLIT 2

/* Stage34: telemetry ONLY. Never changes IRQ lifetime, return codes or waits. */
static bool iris34_irq_diag;
module_param_named(iris34_irq_diag, iris34_irq_diag, bool, 0600);
MODULE_PARM_DESC(iris34_irq_diag, "Stage34 diagnostic IRQ logs (default OFF)");
''')

# Scope modifications to one function each, avoiding ambiguous global matches.
def scoped(label, begin, end, changes):
    global s
    i=s.find(begin)
    if i < 0 or s.find(begin,i+1) >= 0:
        raise SystemExit(f'BLOCKED: Stage34 {label} function boundary')
    j=s.find(end,i+len(begin))
    if j < 0:
        raise SystemExit(f'BLOCKED: Stage34 {label} function end')
    sub=s[i:j]
    for n, old, new in changes:
        cnt=sub.count(old)
        if cnt != 1:
            raise SystemExit(f'BLOCKED: Stage34 {label}:{n} anchor count {cnt}')
        sub=sub.replace(old,new,1)
    s=s[:i]+sub+s[j:]

scoped('wait', 'int sde_encoder_helper_wait_for_irq(', '\nint sde_encoder_helper_register_irq(', [
 ('local','\tint ret, i;\n','\tint ret, i;\n\tint iris34_entry_irq = -EINVAL;\n'),
 ('entry','\tirq = &phys_enc->irq[intr_idx];\n',
  '\tirq = &phys_enc->irq[intr_idx];\n\tiris34_entry_irq = READ_ONCE(irq->irq_idx);\n'),
 ('postwait','\tif (ret <= 0) {\n\t\tirq_status = sde_core_irq_read(phys_enc->sde_kms,',
'''\tif (ret <= 0) {
        if (READ_ONCE(iris34_irq_diag))
            SDE_ERROR_PHYS(phys_enc,
                "IRIS34_IRQ_WAIT_POST intr=%d entry=%d now=%d hw=%d pending=%d state=%d timeout_ms=%lld\\n",
                intr_idx, iris34_entry_irq, READ_ONCE(irq->irq_idx),
                irq->hw_idx, atomic_read(wait_info->atomic_cnt),
                phys_enc->enable_state, (long long)wait_info->timeout_ms);
\t\tirq_status = sde_core_irq_read(phys_enc->sde_kms,'''),
 ('timeout','\t\t} else {\n\t\t\tret = -ETIMEDOUT;\n',
'''\t\t} else {
            if (READ_ONCE(iris34_irq_diag))
                SDE_ERROR_PHYS(phys_enc,
                    "IRIS34_IRQ_TIMEOUT intr=%d entry=%d after=%d hw=%d pending=%d\\n",
                    intr_idx, iris34_entry_irq,
                    READ_ONCE(irq->irq_idx), irq->hw_idx,
                    atomic_read(wait_info->atomic_cnt));
\t\t\tret = -ETIMEDOUT;
''')
])

scoped('register', 'int sde_encoder_helper_register_irq(', '\nint sde_encoder_helper_unregister_irq(', [
 ('success','\tSDE_DEBUG_PHYS(phys_enc, "registered irq %s idx: %d\\n",\n\t\t\tirq->name, irq->irq_idx);',
'''\tif (READ_ONCE(iris34_irq_diag))
        SDE_ERROR_PHYS(phys_enc, "IRIS34_IRQ_REGISTER intr=%d hw=%d idx=%d\\n",
                intr_idx, irq->hw_idx, READ_ONCE(irq->irq_idx));
\tSDE_DEBUG_PHYS(phys_enc, "registered irq %s idx: %d\\n",
\t\t\tirq->name, irq->irq_idx);''')
])
scoped('unregister', 'int sde_encoder_helper_unregister_irq(', '\nvoid sde_encoder_get_hw_resources(', [
 ('before-clear','\tirq->irq_idx = -EINVAL;\n',
'''\tif (READ_ONCE(iris34_irq_diag))
        SDE_ERROR_PHYS(phys_enc, "IRIS34_IRQ_UNREGISTER intr=%d hw=%d before_clear=%d\\n",
                intr_idx, irq->hw_idx, READ_ONCE(irq->irq_idx));
\tirq->irq_idx = -EINVAL;
''')
])
scoped('event', 'int sde_encoder_wait_for_event(', '\nvoid sde_encoder_helper_get_jitter_bounds_ns(', [
 ('failure','\t\t\tif (ret) {\n\t\t\t\tSDE_ERROR_ENC(sde_enc,',
'''\t\t\tif (ret) {
                if (READ_ONCE(iris34_irq_diag))
                    SDE_ERROR_ENC(sde_enc,
                        "IRIS34_WAIT_EVENT_FAIL event=%d phys=%d ret=%d\\n", event, i, ret);
\t\t\t\tSDE_ERROR_ENC(sde_enc,''')
])
for marker in ('IRIS34_IRQ_WAIT_POST','IRIS34_IRQ_TIMEOUT','IRIS34_IRQ_REGISTER',
               'IRIS34_IRQ_UNREGISTER','IRIS34_WAIT_EVENT_FAIL'):
    if s.count(marker)!=1:
        raise SystemExit(f'BLOCKED: marker {marker} missing or duplicated')
p.write_text(s)
print('STAGE34 APPLY PASS; one file modified, opt-in read-only IRQ logging default OFF')
