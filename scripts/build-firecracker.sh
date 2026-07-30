#!/bin/bash
set -euxo pipefail
. "$(dirname "$0")/lib/guard.sh"
require_linux
. "$(dirname "$0")/lib/env.sh"
SRC=${FC_SRC:-$DAEDAL_FC_SRC}
ARCH_TARGET="${1:-$DAEDAL_ARCH-unknown-linux-gnu}"   # x86_64-unknown-linux-gnu | aarch64-unknown-linux-gnu
OUTNAME="${2:-firecracker-$DAEDAL_ARCH}"
JOBS="${3:-$( (nproc 2>/dev/null || echo 2) )}"

if [ ! -d "$SRC" ]; then
  echo "ERROR: firecracker source not found at $SRC" >&2
  echo "Clone it first (scripts/wsl-provision.sh does this on WSL):" >&2
  echo "    git clone https://github.com/firecracker-microvm/firecracker $SRC" >&2
  exit 1
fi

if [ ! -x ~/.cargo/bin/cargo ] && ! command -v cargo >/dev/null 2>&1; then
  curl -sSf --proto '=https' --tlsv1.2 https://sh.rustup.rs -o /tmp/rustup-init.sh
  sh /tmp/rustup-init.sh -y --default-toolchain stable --profile minimal
fi
[ -f ~/.cargo/env ] && source ~/.cargo/env
rustup target add "$ARCH_TARGET" || true

cd "$SRC"
CARGO_TERM_PROGRESS_WHEN=never cargo build --release --target "$ARCH_TARGET" \
  --package firecracker --package jailer -j "$JOBS"
# The uffd post-copy handler the migration scripts use is an example binary in
# the firecracker tree; build it too so daedal_find_uffd can locate it.
CARGO_TERM_PROGRESS_WHEN=never cargo build --release --target "$ARCH_TARGET" \
  --package firecracker --example uffd_on_demand_handler -j "$JOBS" || \
  echo "WARN: uffd_on_demand_handler example did not build; the Uffd backend will be unavailable" >&2

# The release dir depends on whether the checkout redirects cargo's target dir.
REL=
for d in "$SRC/build/cargo_target/$ARCH_TARGET/release" "$SRC/target/$ARCH_TARGET/release"; do
  [ -x "$d/firecracker" ] && REL=$d && break
done
[ -n "$REL" ] || { echo "ERROR: built firecracker not found under $SRC" >&2; exit 1; }

OUT=$DAEDAL_BUILD
mkdir -p "$OUT"
cp "$REL/firecracker" "$OUT/$OUTNAME"
"$OUT/$OUTNAME" --version | head -1
file "$OUT/$OUTNAME"
echo FC_BUILD_DONE_$OUTNAME
