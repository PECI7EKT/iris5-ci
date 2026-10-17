#!/usr/bin/env bash
set -euo pipefail
mkdir -p sources ci-out
fetch_commit() {
  local label="$1" url="$2" sha="$3"
  local dir="sources/$label"
  git init -q "$dir"
  git -C "$dir" remote add origin "$url"
  # No full source checkout in audit. Blobless shallow Git fetch of a pinned commit.
  git -C "$dir" -c protocol.version=2 fetch --no-tags --depth=1 --filter=blob:none origin "$sha"
  local actual
  actual="$(git -C "$dir" rev-parse FETCH_HEAD)"
  test "$actual" = "$sha" || { echo "Invalid $label commit: $actual" >&2; exit 1; }
  echo "$label $actual" | tee -a ci-out/source_sha.txt
}
fetch_commit kernel https://github.com/realme-GT-Neo5-Development/sm8450-6.6.git \
  45174e44b18f5d9024b3024e3de0d48c610b2bb3
fetch_commit modules https://github.com/realme-GT-Neo5-Development/sm8450-modules-6.6.git \
  34e2cb16f16f81d0eec75dde4915d5f139491b4d
fetch_commit devicetrees https://github.com/realme-GT-Neo5-Development/sm8450-devicetrees-6.6.git \
  dde9dc800c75af64dca9f90569afefb495389d71

git -C sources/kernel show FETCH_HEAD:Makefile | grep -q '^SUBLEVEL = 139$'
git -C sources/kernel show FETCH_HEAD:build.config.constants | grep -q '^CLANG_VERSION=r510928$'
git -C sources/modules show FETCH_HEAD:qcom/opensource/display-drivers/msm/iris/Kbuild | grep -q 'iris5/Kbuild'
printf 'Source fingerprints and expected Iris5 Kbuild: PASS\n' | tee ci-out/source_check.txt
