# shellcheck shell=bash
# Sourced by scripts that must run on Linux: they use Linux-only tooling
# (mkfs.ext4, mount -o loop, ip, podman, make, /dev/kvm) that does not exist on
# macOS or Windows.
#
# On macOS: Lima mounts the repo at the same path inside the VM, so when a
# guarded script is run on the macOS host, require_linux transparently
# re-executes it inside the VM (arguments and exit code preserved) instead of
# failing with a cryptic "command not found".
#
# On Windows: run the scripts inside WSL2 from a repo cloned onto the Linux
# filesystem (NOT /mnt/c) -- see docs/RUN-ON-WINDOWS.md. WSL2 is already
# Linux, so no forwarding is needed; require_linux only refuses to run from a
# Windows drive mount, where ext4 loop mounts are unreliable.
#
# Knobs: DAEDAL_VM overrides the target Lima VM (default daedal-kvm, e.g.
# daedal-pvm for the PVM path); DAEDAL_NO_FORWARD=1 disables forwarding and
# fails fast with the actionable error instead.
#
# Usage, right after the shebang and `set -...` line:
#   . "$(dirname "$0")/lib/guard.sh"
#   require_linux              # OS check only
#   require_linux mkfs.ext4    # OS check plus specific command(s)

# Captured at source time: the calling script's own arguments, quoted so they
# survive the trip through `bash -lc` (bash-3.2-safe; no arrays under set -u).
GUARD_FWD_ARGS=""
for guard_fwd_a in "$@"; do
  GUARD_FWD_ARGS="$GUARD_FWD_ARGS $(printf %q "$guard_fwd_a")"
done

require_linux() {
  if [ "$(uname -s)" = "Linux" ]; then
    # Already Linux (a Lima VM, WSL2, or a bare Linux host). Refuse to run
    # from a Windows drive mount: loop-mounting ext4 images on /mnt/* fails,
    # and multi-GB build artifacts do not belong on a synced Windows folder.
    repo=$(cd "$(dirname "$0")/.." && pwd)
    case "$repo" in
      /mnt/[a-zA-Z]/*)
        script=$(basename "$0")
        {
          echo "ERROR: $script is running from a Windows drive mount ($repo)."
          echo "ext4 loop mounts do not work reliably there, and builds write"
          echo "multi-GB images. Clone the repo onto the Linux filesystem first:"
          echo
          echo "    git clone $repo \$HOME/daedal"
          echo "    cd \$HOME/daedal && bash scripts/$script"
          echo
          echo "See docs/RUN-ON-WINDOWS.md for the full Windows/WSL2 setup."
        } >&2
        exit 1
        ;;
    esac
  else
    script=$(basename "$0")
    repo=$(cd "$(dirname "$0")/.." && pwd)
    vm="${DAEDAL_VM:-daedal-kvm}"
    if [ -z "${DAEDAL_NO_FORWARD:-}" ] && command -v limactl >/dev/null 2>&1 \
       && limactl list 2>/dev/null | awk -v v="$vm" '$1 == v && $2 == "Running" { found = 1 } END { exit !found }'; then
      echo "guard: $script needs Linux; running it inside the '$vm' VM (DAEDAL_NO_FORWARD=1 disables)" >&2
      exec limactl shell "$vm" -- bash -lc \
        "cd $(printf %q "$repo") && DAEDAL_NO_FORWARD=1 bash $(printf %q "scripts/$script")$GUARD_FWD_ARGS"
    fi
    {
      echo "ERROR: $script uses Linux-only tooling and cannot run on this host,"
      echo "and auto-forwarding is unavailable (limactl missing, VM '$vm' not Running,"
      echo "or DAEDAL_NO_FORWARD set)."
      echo
      echo "On macOS: start the VM, then re-run -- the script forwards into it"
      echo "automatically:"
      echo
      echo "    limactl start $vm"
      echo "    bash scripts/$script"
      echo
      echo "Or run it manually inside the VM (the repo is mounted at the same path):"
      echo
      echo "    limactl shell $vm"
      echo "    cd $repo"
      echo "    bash scripts/$script"
      echo
      echo "On Windows: run inside WSL2 from a repo cloned onto the Linux"
      echo "filesystem -- see docs/RUN-ON-WINDOWS.md."
      echo
      echo "See AGENTS.md \"Host / VMs\" for the VM setup."
    } >&2
    exit 1
  fi
  missing=
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
  done
  if [ -n "$missing" ]; then
    script=$(basename "$0")
    {
      echo "ERROR: $script needs command(s) not found on this host:$missing"
      echo "Install them (e.g. 'sudo apt-get install e2fsprogs' for mkfs.ext4,"
      echo "or run scripts/wsl-provision.sh on WSL), then re-run: bash scripts/$script"
    } >&2
    exit 1
  fi
}
