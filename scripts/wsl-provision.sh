#!/bin/bash
# One-shot, idempotent setup for running daedal on WSL2 (or any apt-based
# Linux). Installs the toolchain and dependencies, clones the firecracker
# source, and finishes with a PASS/WARN/FAIL preflight report instead of dying
# on the first problem. Safe to re-run at any time.
#
# Knobs: GO_VERSION, NODE_MAJOR, DAEDAL_FC_SRC (see lib/env.sh).
set -uo pipefail
. "$(dirname "$0")/lib/guard.sh"
require_linux
. "$(dirname "$0")/lib/env.sh"

GO_VERSION=${GO_VERSION:-1.24.4}
NODE_MAJOR=${NODE_MAJOR:-22}
FC_REPO=${FC_REPO:-https://github.com/firecracker-microvm/firecracker}

echo "=== apt packages ==="
sudo apt-get update -qq
sudo apt-get install -y -qq \
  build-essential gcc git curl file pkg-config \
  e2fsprogs busybox-static debootstrap \
  podman iproute2 iptables python3 \
  libseccomp-dev clang libclang-dev >/dev/null
echo "apt packages installed"

echo "=== Go (>= 1.24 required by api/go.mod) ==="
GO_OK=
if command -v go >/dev/null 2>&1; then
  GOV=$(go version | grep -oE 'go[0-9]+\.[0-9]+' | head -1 | sed 's/go//')
  case "$GOV" in
    1.2[4-9]|1.[3-9]*|[2-9].*) GO_OK=1 ;;
  esac
fi
if [ -z "$GO_OK" ]; then
  echo "installing Go $GO_VERSION to /usr/local/go"
  curl -fsSL "https://go.dev/dl/go$GO_VERSION.linux-$DAEDAL_GOARCH.tar.gz" -o /tmp/go.tar.gz
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf /tmp/go.tar.gz
  rm -f /tmp/go.tar.gz
  if ! grep -q '/usr/local/go/bin' "$HOME/.profile" 2>/dev/null; then
    echo 'export PATH=$PATH:/usr/local/go/bin' >> "$HOME/.profile"
  fi
  export PATH=$PATH:/usr/local/go/bin
fi
go version

echo "=== Rust (for firecracker and the gateway crates) ==="
if [ ! -x "$HOME/.cargo/bin/cargo" ] && ! command -v cargo >/dev/null 2>&1; then
  curl -sSf --proto '=https' --tlsv1.2 https://sh.rustup.rs -o /tmp/rustup-init.sh
  sh /tmp/rustup-init.sh -y --default-toolchain stable --profile minimal
  rm -f /tmp/rustup-init.sh
fi
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
cargo --version

echo "=== Node.js (>= 20 required by vite; installing $NODE_MAJOR.x LTS) ==="
NODE_OK=
if command -v node >/dev/null 2>&1; then
  NV=$(node --version | sed 's/^v//' | cut -d. -f1)
  [ "$NV" -ge 20 ] 2>/dev/null && NODE_OK=1
fi
if [ -z "$NODE_OK" ]; then
  curl -fsSL "https://deb.nodesource.com/setup_$NODE_MAJOR.x" | sudo -E bash - >/dev/null
  sudo apt-get install -y -qq nodejs >/dev/null
fi
node --version; npm --version

echo "=== firecracker source ($FC_REPO) ==="
if [ ! -d "$DAEDAL_FC_SRC/.git" ]; then
  mkdir -p "$(dirname "$DAEDAL_FC_SRC")"
  git clone --depth 50 "$FC_REPO" "$DAEDAL_FC_SRC"
else
  echo "already cloned at $DAEDAL_FC_SRC"
fi

echo
echo "=== preflight report ==="
PASS=0; WARN=0; FAIL=0
ok()   { echo "PASS  $1"; PASS=$((PASS+1)); }
warn() { echo "WARN  $1"; WARN=$((WARN+1)); }
bad()  { echo "FAIL  $1"; FAIL=$((FAIL+1)); }

if [ -e /dev/kvm ]; then
  ok "/dev/kvm present (nested virtualization works)"
else
  bad "/dev/kvm missing. On WSL2: run 'wsl --update' from Windows, then 'wsl --shutdown', and check virtualization (SVM/VT-x) is enabled in the BIOS."
fi

if [ -e /dev/userfaultfd ]; then
  ok "/dev/userfaultfd present (Uffd memory backend available)"
else
  warn "/dev/userfaultfd missing (kernel $(uname -r) < 6.1). The default File backend works; for the Uffd backend run 'wsl --update' from Windows, then 'wsl --shutdown'."
fi

case "$DAEDAL_ROOT" in
  /mnt/[a-zA-Z]/*) bad "repo is on a Windows drive mount ($DAEDAL_ROOT); clone it onto the Linux filesystem: git clone $DAEDAL_ROOT \$HOME/daedal" ;;
  *) ok "repo on the Linux filesystem ($DAEDAL_ROOT)" ;;
esac

MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
if [ "${MEM_MB:-0}" -ge 6500 ]; then
  ok "memory: ${MEM_MB} MiB available to Linux"
else
  warn "memory: only ${MEM_MB:-?} MiB. The GUI demo (two 1 GiB desktop guests + a 1 GiB snapshot on /dev/shm) wants ~6.5 GiB+. On WSL2 raise it in C:\\Users\\<you>\\.wslconfig ([wsl2] memory=10GB) then 'wsl --shutdown'."
fi

if grep -qE 'svm|vmx' /proc/cpuinfo; then
  ok "CPU virtualization flags visible ($(grep -oE 'svm|vmx' /proc/cpuinfo | head -1))"
else
  warn "no svm/vmx flag in /proc/cpuinfo; firecracker may still work if /dev/kvm exists"
fi

for c in go cargo node npm podman debootstrap busybox gcc mkfs.ext4 python3; do
  if command -v "$c" >/dev/null 2>&1; then :; else bad "missing command after install: $c"; fi
done
ok "toolchain: go=$(go version | awk '{print $3}') cargo=$(cargo --version | awk '{print $2}') node=$(node --version) podman=$(podman --version | awk '{print $3}')"

echo
echo "preflight: $PASS pass, $WARN warn, $FAIL fail"
if [ "$FAIL" -gt 0 ]; then
  echo "PROVISION_FAILED (fix the FAIL lines above and re-run)"
  exit 1
fi
if ! grep -qi microsoft /proc/version 2>/dev/null; then
  echo "note: this does not look like WSL; that is fine, any Linux with /dev/kvm works."
fi
echo PROVISION_DONE
