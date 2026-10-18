# Iris5 Stage20 — EROFS candidate generation, NOT flash approval

The original source is `vendor_dlkm.img` (31,768,576 bytes) from the genuine October 6 `senna-6.6.139-gki+-20261006-2201-ak3.zip`. The Android module must be the original from Stage 18, unchanged by I1–P5 or D1. The wrapper checks fixed SHA-256 sums against independently examined files. It never edits boot/vbmeta or flashes.

**Public-source warning:** Creating a GitHub Release in this public repository exposes the uploaded firmware installer publicly. Check the developer's redistribution terms first. Use your own private environment if redistribution is not appropriate.

1. On GitHub, create a release for `PECI7EKT/iris5-ci` with **tag `stage20-input`**, attach precisely `senna-6.6.139-gki+-20261006-2201-ak3.zip`. Do not rename it or upload a different firmware build. Do NOT add this large binary as Git source.
2. Upload `.github/workflows/iris5-stage20-image.yml` and `ci/stage20/repack.sh`, `ci/stage20/manifest.py` to main and commit.
3. Start `Iris5 Stage20 - UNMODIFIED module EROFS image audit`, mode `audit` first. It will verify the source image, original module, stripped module and SELinux label preservation. **It may fail on GitHub's SELinux-disabled filesystem**: failure means *no safe candidate produced*, not permission to bypass metadata checks.
4. Only when `audit` passes, try mode `assemble`. It rebuilds and extracts an EROFS image and compares all files and metadata. The final candidate is uploaded only if all checks pass and size <=31,768,576 bytes. If the candidate fails, do not flash any intermediate file.
5. Before any experimental installation, compare the copy on your phone with the source archive, keep offline known-good vendor_dlkm and the complete restore procedure ready. Even all static checks are not proof of runtime compatibility; filesystem AVB integrity and display startup remain to be reviewed.

**Scope:** CPU architecture, BTF, KCFI, imported-symbol CRC and vermagic were already validated by Stage18, but module runtime, Android `modules.load` and EROFS/AVB behavior must be re-validated independently. The compiled Stage18 file is ~44.95 MB unstripped. `llvm-objcopy --strip-debug` reduces it significantly while preserving `.BTF`, `__versions`, `.modinfo` and `.symtab`.
