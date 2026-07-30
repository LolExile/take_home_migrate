#!/bin/bash
set -euxo pipefail
. "$(dirname "$0")/lib/env.sh"
ARCH="${1:-$DAEDAL_ARCH}"   # x86_64 | aarch64
OUT=$DAEDAL_BUILD
mkdir -p "$OUT"
CI=https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.12/$ARCH

# Guest kernel (uncompressed vmlinux the KVM path boots directly). The bucket
# names carry the full patch version (e.g. vmlinux-6.1.128) and differ per
# arch, so discover the newest 6.1 kernel instead of hardcoding a name.
KEY=$(curl -fsSL "https://s3.amazonaws.com/spec.ccfc.min?list-type=2&prefix=firecracker-ci/v1.12/$ARCH/vmlinux-6.1" \
  | tr '<' '\n' | sed -n 's/^Key>//p' | grep -E 'vmlinux-6\.1\.[0-9]+$' | sort -V | tail -1)
if [ -n "$KEY" ]; then
  curl -fsSL "https://s3.amazonaws.com/spec.ccfc.min/$KEY" -o "$OUT/vmlinux-$ARCH"
else
  # fall back to the fixed names older bucket layouts used
  curl -fsSL "$CI/vmlinux-6.1.bin" -o "$OUT/vmlinux-$ARCH" \
    || curl -fsSL "$CI/vmlinux.bin" -o "$OUT/vmlinux-$ARCH"
fi

# Rootfs squashfs -> ext4 (writable, needed for our heartbeat agent).
curl -fsSL "$CI/ubuntu-24.04.squashfs" -o "$OUT/rootfs-$ARCH.squashfs"

file "$OUT/vmlinux-$ARCH"
ls -la "$OUT"/vmlinux-"$ARCH" "$OUT"/rootfs-"$ARCH".squashfs
echo FETCH_DONE_$ARCH
