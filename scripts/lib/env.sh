# shellcheck shell=bash
# Sourced by scripts. Discovers, instead of hardcoding, everything that used to
# be machine-specific (repo root, CPU architecture, artifact names), so the
# same scripts run unchanged on any host: the original macOS + Lima setup
# (aarch64), a Windows machine via WSL2 (x86_64), or any other Linux box.
# Every value can be overridden by exporting it before running the script.
#
#   DAEDAL_ROOT     repo root; default: the parent of the scripts/ dir holding this file
#   DAEDAL_ARCH     uname -m normalized to x86_64 | aarch64
#   DAEDAL_GOARCH   amd64 | arm64 (Go's name for DAEDAL_ARCH)
#   DAEDAL_BUILD    artifact dir; default $DAEDAL_ROOT/kernel/build
#   DAEDAL_FC_BIN   the firecracker binary for this arch
#   DAEDAL_VMLINUX  the guest kernel for this arch
#   DAEDAL_DAEDALD  the daedald orchestrator binary for this arch
#   DAEDAL_FC_SRC   the firecracker source checkout (builds + the uffd handler)
#
# Helpers:
#   daedal_find_uffd       prints the built uffd_on_demand_handler path (or nothing)
#   daedal_ensure_daedald  builds DAEDAL_DAEDALD with go if it is missing
#
# Usage, right after guard.sh:
#   . "$(dirname "$0")/lib/env.sh"

if [ -z "${DAEDAL_ROOT:-}" ]; then
  DAEDAL_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
fi

case "${DAEDAL_ARCH:-$(uname -m)}" in
  x86_64|amd64)  DAEDAL_ARCH=x86_64;  DAEDAL_GOARCH=amd64 ;;
  aarch64|arm64) DAEDAL_ARCH=aarch64; DAEDAL_GOARCH=arm64 ;;
  *)
    echo "ERROR: unsupported architecture '$(uname -m)' (need x86_64 or aarch64)" >&2
    exit 1
    ;;
esac

# Smallest guest RAM the CI guest kernel boots in. x86_64 kernels load at
# physical 16 MiB and their segments extend past 32 MiB, so the 32 MiB guest
# the aarch64 path uses does not boot there (measured: 48 works, 32 does not;
# 64 leaves headroom for kernel updates).
case "$DAEDAL_ARCH" in
  x86_64)  DAEDAL_MIN_GUEST_MIB=${DAEDAL_MIN_GUEST_MIB:-64} ;;
  aarch64) DAEDAL_MIN_GUEST_MIB=${DAEDAL_MIN_GUEST_MIB:-32} ;;
esac

DAEDAL_BUILD=${DAEDAL_BUILD:-$DAEDAL_ROOT/kernel/build}
DAEDAL_FC_BIN=${DAEDAL_FC_BIN:-$DAEDAL_BUILD/firecracker-$DAEDAL_ARCH}
DAEDAL_VMLINUX=${DAEDAL_VMLINUX:-$DAEDAL_BUILD/vmlinux-$DAEDAL_ARCH}
DAEDAL_DAEDALD=${DAEDAL_DAEDALD:-$DAEDAL_ROOT/bin/daedald-linux-$DAEDAL_GOARCH}
DAEDAL_FC_SRC=${DAEDAL_FC_SRC:-$HOME/fc/firecracker-next}

# The uffd handler is an example binary inside the firecracker build tree; its
# location depends on whether the checkout redirects cargo's target dir.
# find exits nonzero when one of the two candidate dirs does not exist, which
# under a caller's `set -e -o pipefail` would silently kill the script, so
# swallow its status: an empty result is the meaningful failure signal here.
daedal_find_uffd() {
  { find "$DAEDAL_FC_SRC/build" "$DAEDAL_FC_SRC/target" \
      -name uffd_on_demand_handler -type f 2>/dev/null || true; } | head -1
}

daedal_ensure_daedald() {
  [ -x "$DAEDAL_DAEDALD" ] && return 0
  if ! command -v go >/dev/null 2>&1; then
    echo "ERROR: $DAEDAL_DAEDALD is missing and go is not installed to build it." >&2
    echo "Install Go (see scripts/wsl-provision.sh) or build it on a machine that has Go:" >&2
    echo "    cd api && GOOS=linux GOARCH=$DAEDAL_GOARCH CGO_ENABLED=0 go build -o ../bin/daedald-linux-$DAEDAL_GOARCH ./cmd/daedald" >&2
    return 1
  fi
  echo "env: building missing $DAEDAL_DAEDALD (linux/$DAEDAL_GOARCH, no cgo)" >&2
  mkdir -p "$DAEDAL_ROOT/bin"
  ( cd "$DAEDAL_ROOT/api" && GOOS=linux GOARCH="$DAEDAL_GOARCH" CGO_ENABLED=0 \
      go build -o "$DAEDAL_DAEDALD" ./cmd/daedald )
}
