# Iris5 Stage 19 — source/ABI-only experimental variants

Prerequisites: successful GitHub Actions Stage17 foundation #8 and Stage18 baseline #3.
This package adds files only; it does not edit Stage17/18.

## Upload

Commit files to `PECI7EKT/iris5-ci` branch `main`, preserving paths:

- `.github/workflows/iris5-stage19.yml`
- `ci/stage19/run.sh`
- `ci/stage19/verify_variant.py`
- `ci/stage19/patches/*.patch` (six files)

Use Actions -> **Iris5 6.6.139 - Stage19 patch variants ABI audit** -> Run workflow:

1. `verify`: source pins and strict `git apply --check` + `git diff --check` on each
   variant. No ARM64 build. If this fails, review artifact logs rather than
   forcing patch hunks.
2. `build`: re-creates the exact Stage18 baseline from Stage17 foundation #8,
   builds external providers and the unchanged baseline, then compiles 7
   isolated patched modules. No installing, signing, packaging, or flashing.
   Build mode also executes `verify` first.

Variants:

- `I1` — complete I2C transfers
- `P1P2` — propagate PT/ESD error
- `P3` — reject unready PT FIFO
- `P4` — PT response bounds
- `P1P2_P5` — P5 diagnostic check with mandatory P2 early-break
- `I1_P1P2_P3_P4_P5` — functional cumulative patch set
- `D1` — SSC register readback diagnostics only, **not** mixed with fixes

Original P5 for the braced 5.10 source DOES NOT apply to this 6.6.139 branch.
This package includes a **new, pinned P5-66 adaptation** with one logical
condition added to the exact unbraced `dsi_display.c` source. Original uploads
remain unchanged. D1 uses a display-msm-relative path; script explicitly
handles its `--directory` option.

ABI comparison uses the same Stage18 verification logic: 763/763 imported
symbol CRCs, ARM64 ELF64, BTF, KCFI and vermagic. This is only a **necessary
compatibility check**, not proof of physical safety, correct runtime locking,
full ABI equivalence, or recovery of MEMC/SDR2HDR.

`ci-out/stage19/modules/*.ko` are **offline artifacts only**, NOT installation
instructions or approved flashable modules. Don't test hardware before a
separate risk/recovery plan and detailed review.

The upstream base originally shown in I1–P5 patches is a different source
revision. Stage15 source review found I1–P4 still textually applicable and a
P5-66 adaptation necessary. This Stage19 workflow will independently check
textual application to pinned modules SHA `34e2cb16...` before compiling.

GitHub Actions artifact retention: 14 days. Avoid GitHub 'Re-run jobs' after
changing files; dispatch a new workflow run instead.
