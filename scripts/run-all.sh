#!/bin/bash
# One-command entry point: provision (if needed), build whatever is missing,
# launch the GUI live-migration demo, and print the URL. Idempotent: every
# step is skipped when its artifact already exists, so re-runs are fast.
#
#   bash scripts/run-all.sh              # setup + GUI demo, hold until Ctrl-C
#   bash scripts/run-all.sh --with-bench # also run the two migration proofs
#   bash scripts/run-all.sh --no-hold    # exit after starting (for scripts);
#                                        # stop later with scripts/stop-demo.sh
#
# While holding, Ctrl-C tears everything down via stop-demo.sh.
set -uo pipefail
. "$(dirname "$0")/lib/guard.sh"
require_linux
. "$(dirname "$0")/lib/env.sh"

WITH_BENCH=
HOLD=1
for a in "$@"; do
  case "$a" in
    --with-bench) WITH_BENCH=1 ;;
    --no-hold)    HOLD= ;;
    *) echo "usage: run-all.sh [--with-bench] [--no-hold]" >&2; exit 2 ;;
  esac
done

step() { echo; echo "==== $1"; }
cd "$DAEDAL_ROOT"

step "0/6 toolchain"
if command -v go >/dev/null 2>&1 && command -v cargo >/dev/null 2>&1 \
   && command -v npm >/dev/null 2>&1 && command -v podman >/dev/null 2>&1 \
   && command -v debootstrap >/dev/null 2>&1; then
  echo "toolchain present, skipping provision"
else
  bash scripts/wsl-provision.sh || exit 1
  # pick up PATH additions (go) without requiring a new shell
  export PATH=$PATH:/usr/local/go/bin
  [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
fi

step "1/6 firecracker ($DAEDAL_FC_BIN)"
if [ -x "$DAEDAL_FC_BIN" ]; then echo "present, skipping"; else
  bash scripts/build-firecracker.sh || exit 1
fi

step "2/6 guest kernel ($DAEDAL_VMLINUX)"
if [ -f "$DAEDAL_VMLINUX" ]; then echo "present, skipping"; else
  bash scripts/fetch-guest-images.sh || exit 1
fi

step "3/6 guest images (heartbeat + beacon)"
[ -f "$DAEDAL_BUILD/rootfs.ext4" ]     && echo "rootfs.ext4 present"     || bash scripts/build-rootfs.sh     || exit 1
[ -f "$DAEDAL_BUILD/rootfs-net.ext4" ] && echo "rootfs-net.ext4 present" || bash scripts/build-net-rootfs.sh || exit 1

step "4/6 container host image"
[ -d "$HOME/host-rootfs/bin" ] && echo "present, skipping" || bash scripts/build-host-image.sh || exit 1

if [ -n "$WITH_BENCH" ]; then
  step "bench: blackout p99 (100 runs) -- keep the machine idle"
  bash scripts/blackout-p99.sh 100 || exit 1
  step "bench: two-host live migration (packet-loss proof)"
  bash scripts/two-host-demo.sh || exit 1
fi

step "5/6 desktop image (first build takes ~13 min)"
if [ -f "$DAEDAL_BUILD/rootfs-desktop.ext4" ]; then echo "present, skipping"; else
  bash scripts/build-desktop-rootfs.sh || exit 1
fi

step "6/6 GUI demo"
GATEWAY_TARGET=${GATEWAY_TARGET:-$HOME/gateway-target} \
  bash scripts/desktop-migration-demo.sh || exit 1

echo
echo "RUN_ALL_UP -- open the demo URL printed above in your browser."
if [ -n "$HOLD" ]; then
  echo "This shell keeps the demo alive. Press Ctrl-C to stop everything."
  trap 'echo; echo "stopping everything..."; bash scripts/stop-demo.sh; exit 0' INT TERM
  while true; do sleep 3600 & wait $!; done
else
  echo "Started detached. Stop later with: bash scripts/stop-demo.sh"
fi
