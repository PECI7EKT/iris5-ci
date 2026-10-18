# Stage22 / Realme GT Neo 5 Iris5 — SSC A/B against installed Stage21 I1

## Purpose and rationale

A confirmed *active* device tree contains both `qcom,dsi-pll-ssc-en` and
`oplus,dsi-pll-ssc-disalbed` on PHY0 and PHY1. Stock Realme 5.10 code honors
the latter as an override, and Quantom's successful stock boot log reported
`PLL SSC disalbed` for both PLLs. Pinned japq7s 6.6 modules source **does not**
check the Oplus property and would enable SSC on a normal configured PLL path.
**Hardware SSC, lock status and causality remain unproven.**

This kit makes **exactly one behavioral change compared with Stage21 I1**:
a source-level Oplus disable override in `dsi/dsi_pll.c`. It retains the
identical pinned Stage19 I1 patch. It does not change DRM timing, Panel DT,
MEMC/SDR-to-HDR userspace hooks, ESD, D-PHY power, IRQ, DSI read, boot or
recovery. It is an *A/B hypothesis test*, not an established fix.

Sources:
- modules commit `34e2cb16f16f81d0eec75dde4915d5f139491b4d`
- core commit `45174e44b18f5d9024b3024e3de0d48c610b2bb3`
- Stage19 I1 SHA256 `d4a4b0f2a5c796ad642f3c61751b685474dd48750ce740061ce718ed4fcc223b`
- preserved Stage21 I1 built module SHA256 `cecd6506a059a73673b41ff9997844290f361e730d53f0321eaf890f89b3c4c3`

## Install files into existing GitHub repo

Repository: `PECI7EKT/iris5-ci` (existing Stage17/18/19/20/21 inputs must remain
unchanged).

Copy the **three files** with their directory paths:

1. `.github/workflows/iris5-stage22-ssc.yml`
2. `ci/stage22/run.sh`
3. `ci/stage22/patches/0001-SSC-honor-oplus-disable.patch`

Do not change the old I1 patch or any earlier stage. Do not push firmware or
proprietary blobs into a public Git repo.

## Run GitHub Actions

- **Actions → Iris5 Stage22 - I1 plus stock SSC policy (OFFLINE)**
- Select `verify`. Expect `STAGE22 VERIFY PASS`. This checks actual source
  commit, authentic I1 hash, `git apply --check` of both patches and only three
  changed source files. Does not compile.
- Only then run `build`. Expect `STAGE22 BUILD+ABI PASS`, with output in
  `iris5-stage22-build-<number>` → `modules/Stage22_I1_plus_SSC_msm_drm.ko`,
  ABI JSON and logs. Never bypass a failed verification/compile gate.

## Stop before flashing

The GitHub Actions result is **NOT flashable**. A module cannot simply replace
one file inside the EROFS vendor_dlkm partition without preserving all
metadata, AVB and filesystem integrity. Build, strip, repack, check xattrs,
and verify that the other files are byte-identical using the prior Stage20/21
strategy **after independent inspection of the new output**. That distinct
release/restore gate is not included here.

The installed Stage21 I1 image is the A control. The Stage22 I1+SSC image
would be B. Reboot after each flash into identical 90 Hz / `timing@1`, perform
one supervised SDR-to-HDR test per condition with logcat and a robust kernel
logger, and document dphy, GPIO, PT/lightup, and ESD outcomes. Keep the
known-good Stage21 vendor_dlkm and OrangeFox/fastbootd recovery ready.
A successful PT alone is not proof that MEMC works.

**Risk:** A source-level restore of stock SSC precedence may affect display
startup or sleep/wake. The core and module source commits are candidates,
not a cryptographic proof of the exact Oct 6 original binary recipe. Neither
module build nor hardware safety has been executed by this deliverable.
