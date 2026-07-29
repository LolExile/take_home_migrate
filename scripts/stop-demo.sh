#!/bin/bash
# Stop EVERYTHING any demo in this repo starts, freeing the memory it holds:
# daedald, every Firecracker microVM, the uffd handlers, the VNC tunnel agents
# and gateway, the vite dev server, the podman host containers, the taps and
# bridge, and the tmpfs dirs holding memory snapshot images. Idempotent: safe
# to run when nothing (or only some things) are running, and safe to re-run.
set -uo pipefail
. "$(dirname "$0")/lib/guard.sh"
require_linux
. "$(dirname "$0")/lib/env.sh"

killed=0
say() { echo "stop: $1"; }

# daedald (both the migration server and the older serve mode)
for p in $(pgrep -f 'daedald-linux-(arm64|amd64)' 2>/dev/null); do
  say "killing daedald pid $p"
  sudo kill "$p" 2>/dev/null || true
  killed=$((killed+1))
done

# Firecracker VMMs. pkill -x firecracker misses them: the binary can be named
# firecracker-<arch> and /proc/pid/comm truncates to 15 chars, so scan comm
# for the firecracker* prefix (matches AGENTS.md guidance).
for d in /proc/[0-9]*; do
  comm=$(cat "$d/comm" 2>/dev/null) || continue
  case "$comm" in firecracker*) ;; *) continue ;; esac
  p=${d#/proc/}
  say "killing firecracker pid $p ($comm)"
  sudo kill "$p" 2>/dev/null || true
  killed=$((killed+1))
done

# uffd post-copy handlers
for p in $(pgrep -f uffd_on_demand_handler 2>/dev/null); do
  say "killing uffd handler pid $p"
  sudo kill "$p" 2>/dev/null || true
  killed=$((killed+1))
done

# VNC tunnel agents + websocket gateway
sudo pkill -x vnc-tunnel-agent 2>/dev/null && { say "killed vnc-tunnel-agent(s)"; killed=$((killed+1)); }
sudo pkill -x vnc-ws-gateway 2>/dev/null && { say "killed vnc-ws-gateway"; killed=$((killed+1)); }

# vite dev server (started by desktop-migration-demo.sh out of $DAEDAL_ROOT/web)
for p in $(pgrep -f "$DAEDAL_ROOT/web.*vite" 2>/dev/null; pgrep -f 'node .*vite.*--port 5173' 2>/dev/null); do
  say "killing vite dev server pid $p"
  kill "$p" 2>/dev/null || true
  killed=$((killed+1))
done

# beacon collector
for p in $(pgrep -f 'images/collector.py' 2>/dev/null); do
  say "killing collector pid $p"
  sudo kill "$p" 2>/dev/null || true
  killed=$((killed+1))
done

# podman host containers
if command -v podman >/dev/null 2>&1; then
  for c in host-a host-b; do
    if sudo podman container exists "$c" 2>/dev/null; then
      say "removing podman container $c"
      sudo podman rm -f "$c" >/dev/null 2>&1 || true
      killed=$((killed+1))
    fi
  done
fi

sleep 1

# taps and bridge (delete taps first, then the bridge)
for t in tap-lm-a tap-lm-b tap-lm-pin tap-src tap-dst tap-desk tap-desk-b; do
  if ip link show "$t" >/dev/null 2>&1; then
    say "deleting tap $t"
    sudo ip link del "$t" 2>/dev/null || true
  fi
done
if ip link show br0 >/dev/null 2>&1; then
  say "deleting bridge br0"
  sudo ip link del br0 2>/dev/null || true
fi

# tmpfs dirs holding memory images (this is where the real RAM goes)
for d in /dev/shm/dhost /dev/shm/daedal-desk /dev/shm/mig /dev/shm/mig2 /dev/shm/attach /dev/shm/p99-*; do
  [ -e "$d" ] || continue
  say "removing $d"
  sudo rm -rf "$d" 2>/dev/null || true
done

# work dirs (pids/socks/logs only; small, but stale socks break re-runs)
for d in /tmp/daedal-lm-session /tmp/fc-desktop /tmp/fc-desktop-pin /tmp/twohost /tmp/attach /tmp/blackout /tmp/uffdok /tmp/daedald-dead; do
  [ -e "$d" ] || continue
  say "removing $d"
  sudo rm -rf "$d" 2>/dev/null || true
done

echo
leftover=$(for d in /proc/[0-9]*; do c=$(cat "$d/comm" 2>/dev/null) || continue; case "$c" in firecracker*) echo "${d#/proc/} $c";; esac; done)
if [ -n "$leftover" ]; then
  echo "WARNING: firecracker processes still alive:"
  echo "$leftover"
  echo "re-run this script, or 'sudo kill -9 <pid>'"
else
  echo "no firecracker processes remain"
fi
echo "actions taken: $killed"
free -m | awk '/^Mem:/{printf "memory now: %d MiB used / %d MiB total\n", $3, $2}'
echo STOP_DEMO_DONE
