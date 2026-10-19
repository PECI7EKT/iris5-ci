#!/usr/bin/env python3
"""Stage28 corrective changes on top of the strictly pinned Stage27 source tree.

Fail closed on any source drift. This stage changes no PHY registers, GPIO timings,
ESD policy or boot/recovery partitions.
"""
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: apply_fix.py <display-drivers-root>")
root = Path(sys.argv[1])
dsi = root / "msm/dsi/dsi_panel.c"
ocp = root / "msm/iris/iris5/dsi_iris5_lightup_ocp.c"

def patch_file(path, replacements):
    src = path.read_text()
    for label, before, after in replacements:
        n = src.count(before)
        if n != 1:
            raise SystemExit(f"BLOCKED {path}: {label}: expected exactly one anchor, found {n}")
        src = src.replace(before, after, 1)
    path.write_text(src)
    print(f"STAGE28 FIX APPLIED {path}")

patch_file(dsi, [
    ("serialize DSI panel TX",
     "\tif (!panel || !panel->cur_mode)\n\t\treturn -EINVAL;\n\n\tmode = panel->cur_mode;",
     "\tif (!panel || !panel->cur_mode)\n\t\treturn -EINVAL;\n\n\t/* Stage28: restore serialized panel writes from 5.10. */\n\tmutex_lock(&panel->panel_tx_lock);\n\tmode = panel->cur_mode;"),
    ("unlock panel TX on all post-lock paths",
     "\terror:\n\treturn rc;\n}\n\nstatic int dsi_panel_pinctrl_deinit",
     "\terror:\n\tmutex_unlock(&panel->panel_tx_lock);\n\treturn rc;\n}\n\nstatic int dsi_panel_pinctrl_deinit"),
    ("initialize panel TX mutex",
     "\tmutex_init(&panel->panel_lock);\n\n\treturn panel;",
     "\tmutex_init(&panel->panel_lock);\n\tmutex_init(&panel->panel_tx_lock);\n\n\treturn panel;"),
])

patch_file(ocp, [
    ("PT host sender returns status",
     "static void _iris_pt_send_cmds(",
     "static int _iris_pt_send_cmds("),
    ("return Stage26 logged host status",
     "\tIRIS_LOGI(\"IRIS26_OCP_HOST_SEND cmds=%u state=%d rc=%d\",\n\t\tcmds_cnt, panel_cmds.state, send_rc);\n\n\tif (iris_get_cont_splash_type() == IRIS_CONT_SPLASH_LK)\n\t\tiris_print_desc_cmds(panel_cmds.cmds, panel_cmds.count, panel_cmds.state);\n}",
     "\tIRIS_LOGI(\"IRIS26_OCP_HOST_SEND cmds=%u state=%d rc=%d\",\n\t\tcmds_cnt, panel_cmds.state, send_rc);\n\n\tif (iris_get_cont_splash_type() == IRIS_CONT_SPLASH_LK)\n\t\tiris_print_desc_cmds(panel_cmds.cmds, panel_cmds.count, panel_cmds.state);\n\treturn send_rc;\n}"),
    ("PT write returns status",
     "static void _iris_pt_write_panel_cmd(",
     "static int _iris_pt_write_panel_cmd("),
    ("invalid PT write parameters",
     "\tif (!panel || !cmdset) {\n\t\tIRIS_LOGE(\"%s(), invalid panel or cmdset!\", __func__);\n\t\treturn;\n\t}",
     "\tif (!panel || !cmdset) {\n\t\tIRIS_LOGE(\"%s(), invalid panel or cmdset!\", __func__);\n\t\treturn -EINVAL;\n\t}"),
    ("zero PT write commands",
     "\tif (cmdset->count == 0) {\n\t\tIRIS_LOGD(\"%s(), invalid cmdset count!\", __func__);\n\t\treturn;\n\t}",
     "\tif (cmdset->count == 0) {\n\t\tIRIS_LOGD(\"%s(), invalid cmdset count!\", __func__);\n\t\treturn -EINVAL;\n\t}"),
    ("propagate PT allocation error",
     "\tif (cmds_cnt < 0) {\n\t\tIRIS_LOGE(\"%s(), invalide cmds count: %d\", __func__, cmds_cnt);\n\t\treturn;\n\t}",
     "\tif (cmds_cnt < 0) {\n\t\tIRIS_LOGE(\"%s(), invalide cmds count: %d\", __func__, cmds_cnt);\n\t\treturn cmds_cnt;\n\t}"),
    ("PT write initializes rc",
     "\tint cmds_cnt = 0;\n\tu32 offset = 0;",
     "\tint cmds_cnt = 0;\n\tint rc = 0;\n\tu32 offset = 0;"),
    ("propagate PT packet formation and host return",
     "\tif (j != (u32)cmds_cnt)\n\t\tIRIS_LOGE(\"%s(), invalid cmd count: %d, j: %d\",\n\t\t\t\t__func__,\n\t\t\t\tcmds_cnt, j);\n\telse\n\t\t_iris_pt_send_cmds(panel, ptx_cmds, (u32)cmds_cnt);",
     "\tif (j != (u32)cmds_cnt) {\n\t\tIRIS_LOGE(\"%s(), invalid cmd count: %d, j: %d\",\n\t\t\t\t__func__, cmds_cnt, j);\n\t\trc = -EINVAL;\n\t} else {\n\t\trc = _iris_pt_send_cmds(panel, ptx_cmds, (u32)cmds_cnt);\n\t}"),
    ("return PT write result",
     "\tvfree(pocp_cmds);\n\tvfree(ptx_cmds);\n\tpocp_cmds = NULL;\n\tptx_cmds = NULL;\n}",
     "\tvfree(pocp_cmds);\n\tvfree(ptx_cmds);\n\tpocp_cmds = NULL;\n\tptx_cmds = NULL;\n\treturn rc;\n}"),
    ("max packet size propagates send failure",
     "\t_iris_pt_switch_cmd(panel, &local_cmdset, &pkt_size_cmd);\n\t_iris_pt_write_panel_cmd(panel, &local_cmdset);\n\n\treturn 0;",
     "\t_iris_pt_switch_cmd(panel, &local_cmdset, &pkt_size_cmd);\n\treturn _iris_pt_write_panel_cmd(panel, &local_cmdset);"),
    ("read request propagates send failure",
     "\tstruct dsi_cmd_desc *dsi_cmd = cmdset->cmds;\n\tint rc = 0;\n\n\tmemset(&local_cmdset, 0x00, sizeof(local_cmdset));",
     "\tstruct dsi_cmd_desc *dsi_cmd = cmdset->cmds;\n\n\tmemset(&local_cmdset, 0x00, sizeof(local_cmdset));"),
    ("read request returns host result",
     "\t/*passthrough write to panel*/\n\t_iris_pt_write_panel_cmd(panel, &local_cmdset);\n\treturn rc;",
     "\t/*passthrough write to panel*/\n\treturn _iris_pt_write_panel_cmd(panel, &local_cmdset);"),
    ("stop on missing read completion",
     "\tif (intstat & IRIS_TX_READ_ERR_MASK) {\n\t\trc = -1;\n\t\tIRIS_LOGE(\"%s(), Tx read error 0x%x, rc: %d\",\n\t\t\t\t  __func__, intstat, rc);\n\t\treturn rc;\n\t}\n\tval.pld32 = iris_ocp_read(address, cmdset->state);",
     "\tif (intstat & IRIS_TX_READ_ERR_MASK) {\n\t\trc = -EIO;\n\t\tIRIS_LOGE(\"%s(), Tx read error 0x%x, rc: %d\",\n\t\t\t\t  __func__, intstat, rc);\n\t\treturn rc;\n\t}\n\tif (!(intstat & IRIS_TX_READ_RESPONSE_RECEIVED)) {\n\t\tIRIS_LOGE(\"STAGE28_PT_RX_TIMEOUT status=0x%08x polls=%d\",\n\t\t\tintstat, retry_cnt);\n\t\treturn -ETIMEDOUT;\n\t}\n\tval.pld32 = iris_ocp_read(address, cmdset->state);"),
    ("preserve expected RX buffer length",
     "\trbuf = (u8 *)cmdset->cmds[0].msg.rx_buf;\n\trlen = cmdset->cmds[0].msg.rx_len;",
     "\trbuf = (u8 *)cmdset->cmds[0].msg.rx_buf;\n\trlen = cmdset->cmds[0].msg.rx_len;\n\t/* Stage28: do not copy a malformed oversized response. */"),
    ("PT read max packet setup returns failure",
     "\t/*step1  write max packket size*/\n\t_iris_pt_write_max_pkt_size(panel, cmdset);\n\n\tiris_ocp_write_val",
     "\t/*step1  write max packket size*/\n\trc = _iris_pt_write_max_pkt_size(panel, cmdset);\n\tif (rc < 0)\n\t\tgoto exit;\n\n\tiris_ocp_write_val"),
    ("public PT wrapper propagates errors",
     "\tif (cmdset->count == 1 && iris_is_read_cmd(&cmdset->cmds[0]))\n\t\tiris_pt_read_panel_cmd(panel, cmdset);\n\telse\n\t\t_iris_pt_write_panel_cmd(panel, cmdset);\n\n\treturn 0;",
     "\tif (cmdset->count == 0 || !cmdset->cmds)\n\t\treturn -EINVAL;\n\n\tif (cmdset->count == 1 && iris_is_read_cmd(&cmdset->cmds[0]))\n\t\treturn iris_pt_read_panel_cmd(panel, cmdset);\n\treturn _iris_pt_write_panel_cmd(panel, cmdset);"),
])
print("STAGE28 source corrections applied; no ESD suppression, GPIO changes or PHY writes.")
