# Stage21: isolated I1, Realme GT Neo 5 / LineageOS 24 / kernel 6.6.139-gki+

This stage generates a self-contained EROFS image for **I1 only** (require complete I2C reads and avoid copying failed read outputs). It does not activate HDR/MEMC by itself, and does not include P1/P2/P3/P4/P5/D1 or modify any boot partitions. It is not a device-flash approval.

## Install

Copy exactly these two paths into the existing public `PECI7EKT/iris5-ci` GitHub repository, preserving their paths:

- `.github/workflows/iris5-stage21-I1.yml`
- `ci/stage21/run.sh`

Existing files `ci/stage20/repack.sh`, `ci/stage20/manifest.py` and `ci/stage19/patches/0001-I1-require-complete-i2c-reads.patch` must remain unchanged. The original AK3 remains under Releases tag `stage20-input`.

Go to Actions → **Iris5 Stage21 - isolated I1 module EROFS audit** → Run workflow → `audit`. Verify `STAGE21 I1 AUDIT PASS`, then run the same workflow with `assemble`. When `assemble` succeeds, it will upload `iris5-stage21-I1-assemble-N` with `STAGE21-I1_VENDOR_DLKM_B_OFFLINE_ONLY.img`, SHA256 and manifests. Download results and inspect independently before any device-flash decision. Keep a confirmed original `vendor_dlkm_b` backup in fastbootd recovery reach.

## Inputs pinned

- Stage19 run ID: `39125874244`, artifact `iris5-stage19-build-3`.
- Stage19 `stage19/modules/I1_msm_drm.ko` SHA-256 `cecd6506a059a73673b41ff9997844290f361e730d53f0321eaf890f89b3c4c3`.
- Stripped I1 SHA-256 `01ceed78d74d89db40793c86bf5c233dde879ad26af6e6f34b9f3ab815c48728` (verified offline with LLVM 17; LLVM in workflow may differ: mismatch fails closed).
- I1 patch SHA-256 `d4a4b0f2a5c796ad642f3c61751b685474dd48750ce740061ce718ed4fcc223b`.
- Source `vendor_dlkm.img` SHA-256 `347c16203df84854de9733d1ac4f82cbb08eeae1b3e31bd0e34a81ffbd8365a8`, original device image confirmed identical.

The workflow intentionally reuses successful Stage20 checks and keeps Stage20 source unchanged. This Stage21 ZIP contains neither firmware, proprietary binary blobs nor a flashable image.
