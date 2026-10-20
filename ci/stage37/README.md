# Stage37: automatic ABYP→PT / HWC / state synchronization (SOURCE AUDIT ONLY)

Stage36 `vendor_dlkm_b` remains unchanged. This branch contains a narrowly scoped, **uncompiled** SELinux candidate and a proof-based integration audit; it does not ship a flashable module.

## Directly confirmed

1. Kernel `dsi_iris5_ioctl.c::iris_plus_configure_abyp` compares requested PT with **cached** `abypss_ctrl.abypass_mode` and skips requests matching the cache, without checking the ABYP-ready GPIO. Its `IRIS_ANALOG_BYPASS_MODE` getter also returns that cached field (sleep mode normalized to bypass).
2. Kernel `dsi_iris5_lp.c::_iris_abyp_dbg_read` exposes, through a READ-ONLY `/sys/kernel/debug/iris/abyp` read, both `abyp status gpio` (hardware) and `abyp mode` (cache). This is the required independent comparison. **Never write** to this debugfs file.
3. Stage33 successful hardware PT entry required the DSI postreset pulse in an opt-in controlled test. Stage36 installs with `iris33_postreset_pulse=N`; the normal automatic lifecycle has not been demonstrated.
4. Stage36 logcat contains `IRIS_SDR2HDR_V6` worker, confirming that *some* Composer SDR2HDR client exists in the live build. The name does **not** prove exact source version v6.5/v6.6. The worker uses panel_on gating but 1455 WAIT_VSYNC requests were rejected in 1.40 s after RDPTR unregistration. Fixing the client's retry scheduling is separate from the Stage36 kernel guard.
5. Stage36 AVC: `scontext=u:r:hal_graphics_composer_default:s0`, `property=vendor.iris.sdr2hdr.state`, `tcontext=u:object_r:vendor_default_prop:s0`, `permissive=0`. Scoped property type and composer `set_prop` candidate addresses that **specific** denial without Permissive.
6. Quantom 23.2 `patches/iris.patch` integrates Iris5 wrapper InitPrimaryDisplay and SetColorModeWithRenderIntent; it does NOT add stock-grade BuildLayerStack or SetRefreshCB parity. The separate v4b power hooks and v6.x SDR2HDR worker are additions whose exact built revisions remain unknown.
7. Public `LineageOS/android_hardware_qcom_display` `lineage-24.0-caf-sm8450-6.6` is an **HWC3** codebase with an async SetPowerMode branch that updates software state before the physical power transition is completed by DisplayConfig. Old HWC2 v4b hooks cannot be transplanted without auditing the exact built Composer; do not assume this branch is used on this device.

## Fix sequence

- **SELinux:** Apply the *three* files in sepolicy/vendor to the correct device tree, after resolving existing property types, run Soong/SEPolicy neverallow tests, and verify both state and command writes on-device under Enforcing. No root runtime policy changes.
- **Synchronization:** Capture `/sys/kernel/debug/iris/abyp` + Composer worker logs over screen-off/on. Compare GPIO and cached mode; if disagree, fix cached-mode early-return and error propagation under display lifecycle lock only, after validating which transitions are in flight. Do NOT equate GET267 with PT or force cache to a guessed value.
- **Automatic ABYP→PT:** Port the proven Stage33 clock ON→OFF pulse into the *normal* senna Iris5 entry path behind strict chip/panel/power/ESD guards. Activate from a legitimate graphics service request only after panel power and RDPTR readiness. Do not enable on boot or use repeated retries until multi-cycle tests pass.
- **HWC integration:** Audit the installed executable and loaded `libpwirishalwrapper.so` Build ID/SHA, and match HWC2/HWC3 source. Restore validated before/after power notifications and refresh callbacks with the matching ABI. Do not call guessed vtable offsets.

## Source reference

- Quantom: https://github.com/Quantom2/android_device_realme_senna/blob/985185b036334384689f29d7f159172ad3b33756/patches/iris.patch
- Kernel 6.6 pinned source: https://github.com/realme-GT-Neo5-Development/sm8450-modules-6.6/tree/34e2cb16f16f81d0eec75dde4915d5f139491b4d/qcom/opensource/display-drivers/msm/iris/iris5
- Lineage HWC3 example (not proven as installed): https://github.com/LineageOS/android_hardware_qcom_display/blob/lineage-24.0-caf-sm8450-6.6/composer/hwc_session.cpp

**Not compiled. Not runtime-tested. No flashable artifacts.**