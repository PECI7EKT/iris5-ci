#!/usr/bin/env python3
"""Stage36: bounded missing-RDPTR guard and propagate Iris VBLANK errors.

Intentional scope:
- Preserve Stage35 IRQ telemetry and Stage33 DSI pulse.
- Do not edit IRQ registration, TE source, timeout or pending counter cleanup.
- Fail with -EAGAIN rather than falsely report successful wait if RDPTR
  is already unregistered before enqueue.
- Propagate the real VBLANK wait return code out of iris_wait_vsync().
This does NOT fix an IRQ unregistration that races with an active wait.
"""
from pathlib import Path
import sys
if len(sys.argv)!=2:
    raise SystemExit("usage: apply.py <display-drivers-root>")
root=Path(sys.argv[1])
p=root/"msm/sde/sde_encoder_phys_cmd.c"
q=root/"msm/iris/iris5/dsi_iris5_lightup.c"
s=p.read_text()
v=q.read_text()
if "IRIS36_" in s or "IRIS36_" in v:
    raise SystemExit("BLOCKED: Stage36 already applied")
if "IRIS35_WAIT_BEGIN" not in s:
    raise SystemExit("BLOCKED: Stage35 must be applied first")
start=s.find("static int sde_encoder_phys_cmd_wait_for_vblank(")
end=s.find("\nstatic void sde_encoder_phys_cmd_update_split_role(",start)
if start<0 or end<0:
    raise SystemExit("BLOCKED: VBLANK function scope not found")
sub=s[start:end]
needle="\tatomic_inc(&cmd_enc->pending_vblank_cnt);"
addition='''    /*
     * Stage36: A caller (notably Iris WAIT_VSYNC) may race RSC
     * power-state transitions, where the RDPTR IRQ is already gone.
     * sde_encoder_helper_wait_for_irq() currently returns 0 for an
     * unregistered IRQ. Do not increment pending_vblank_cnt for an
     * event that cannot occur. Report a retryable error to the caller.
     *
     * The IRQ may still unregister AFTER this check. That separate
     * active-wait race remains visible in Stage34/35 diagnostics.
     */
    if (READ_ONCE(phys_enc->irq[INTR_IDX_RDPTR].irq_idx) < 0 ||
        atomic_read(&phys_enc->vblank_refcount) == 0) {
        if (READ_ONCE(iris35_vblank_diag))
            SDE_ERROR_CMDENC(cmd_enc,
                "IRIS36_VBLANK_NOT_ARMED irq=%d ref=%d pending=%d\\n",
                READ_ONCE(phys_enc->irq[INTR_IDX_RDPTR].irq_idx),
                atomic_read(&phys_enc->vblank_refcount),
                atomic_read(&cmd_enc->pending_vblank_cnt));
        return -EAGAIN;
    }
\tatomic_inc(&cmd_enc->pending_vblank_cnt);'''
if sub.count(needle)!=1:
    raise SystemExit(f"BLOCKED: unexpected Stage35 VBLANK inc anchor count {sub.count(needle)}")
sub=sub.replace(needle,addition,1)
s=s[:start]+sub+s[end:]

start=v.find("int iris_wait_vsync(void)")
end=v.find("\nint iris_set_pending_panel_brightness(",start)
if start<0 or end<0:
    raise SystemExit("BLOCKED: iris_wait_vsync function scope not found")
sub=v[start:end]
needle="\tsde_encoder_wait_for_event(drm_enc, MSM_ENC_VBLANK);\n\n\treturn 0;"
replacement='''    /* Stage36: do not hide an unregistered IRQ or actual TE timeout. */
    return sde_encoder_wait_for_event(drm_enc, MSM_ENC_VBLANK);'''
if sub.count(needle)!=1:
    raise SystemExit(f"BLOCKED: unexpected iris_wait_vsync return anchor count {sub.count(needle)}")
sub=sub.replace(needle,replacement,1)
v=v[:start]+sub+v[end:]
if s.count("IRIS36_VBLANK_NOT_ARMED")!=1 or v.count("Stage36: do not hide")!=1:
    raise SystemExit("BLOCKED: Stage36 validation failed")
p.write_text(s)
q.write_text(v)
print("STAGE36 APPLY PASS: no wait enqueued without RDPTR; propagate Iris wait errno")
