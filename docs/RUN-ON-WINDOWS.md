# Running daedal on Windows (WSL2)

Firecracker needs the Linux kernel (`/dev/kvm`, tap devices, ext4 loop
mounts), so nothing here runs on Windows natively -- the same way nothing ran
on macOS natively for the original author, who used a Lima VM. On Windows the
Linux environment is WSL2: a lightweight, built-in Hyper-V VM that exposes
nested virtualization, so Firecracker gets real KVM inside it.

Windows runs only your browser. Everything else -- builds, `daedald`, the
microVMs, the podman "hosts", the VNC gateway, the web dev server -- runs
inside WSL2. WSL forwards `localhost` TCP ports to Windows automatically, so
the GUI at `http://localhost:5173` just works in your Windows browser.

Every script discovers the repo root and CPU architecture at runtime (see
`scripts/lib/env.sh`), so the same scripts run unchanged here (x86_64), on the
original macOS + Lima setup (aarch64), or on any Linux box.

## TL;DR -- one command

After the one-time setup below (sections 0 and 1), everything else is:

```sh
bash scripts/run-all.sh
```

It builds whatever is missing (skipping what exists), starts the GUI demo,
prints the URL, and holds the shell -- Ctrl-C stops and cleans up everything.
`--with-bench` also runs the blackout benchmark and the two-host packet-loss
proof; `--no-hold` starts detached (stop later with `scripts/stop-demo.sh`).

## 0. One-time: Windows side

From PowerShell:

```powershell
wsl --update        # newer kernel; 6.1+ also enables the optional Uffd backend
wsl --shutdown      # restart WSL so the new kernel is used
wsl                 # open your Ubuntu shell
```

If you have never installed WSL: `wsl --install -d Ubuntu` (needs a reboot).
Nested virtualization is on by default on Windows 11; if `/dev/kvm` is missing
inside Ubuntu later, check that SVM (AMD) / VT-x (Intel) is enabled in the
BIOS.

Optional but recommended with 16 GB of RAM, for the GUI demo: create
`C:\Users\<you>\.wslconfig` containing

```ini
[wsl2]
memory=10GB
```

then `wsl --shutdown` and reopen Ubuntu.

## 1. One-time: WSL side

Inside Ubuntu. The repo must live on the Linux filesystem (NOT `/mnt/c/...`):
ext4 loop mounts are unreliable on the Windows mount, and builds write
multi-GB images that OneDrive would try to sync.

```sh
# clone from your Windows checkout (or from GitHub, either works)
git clone /mnt/c/Users/<you>/OneDrive/Desktop/migrate ~/daedal
cd ~/daedal

# install toolchain + deps, clone firecracker, print a preflight report
bash scripts/wsl-provision.sh
```

The provision script is idempotent (safe to re-run) and ends with a
PASS/WARN/FAIL report. Fix any FAIL lines before continuing; WARNs are
optional features. Open a fresh shell afterwards (or `source ~/.profile`) so
`go`, `cargo`, and `node` are on PATH.

## 2. Build everything (in this order)

```sh
cd ~/daedal

# 2a. firecracker + jailer + the uffd handler example (~10 min the first time)
bash scripts/build-firecracker.sh

# 2b. guest kernel from firecracker's CI bucket (~1 min)
bash scripts/fetch-guest-images.sh

# 2c. the 48 MB heartbeat guest (memory-continuity proof) -- seconds
bash scripts/build-rootfs.sh

# 2d. the networked guest with the UDP beacon (packet-loss proof) -- seconds
bash scripts/build-net-rootfs.sh

# 2e. the container-host rootfs podman runs (also builds daedald) -- seconds
bash scripts/build-host-image.sh
```

Each step prints a sentinel on success (`FC_BUILD_DONE_*`, `FETCH_DONE_*`,
`ROOTFS_BUILD_DONE`, `NET_ROOTFS_DONE`, `HOST_IMAGE_DONE`). Artifacts land in
`~/daedal/kernel/build/` with your arch in the name (`firecracker-x86_64`,
`vmlinux-x86_64`).

## 3. Run the migration demos

```sh
# single-host mechanism + blackout distribution: 100 runs (guest size defaults
# to 64 MiB on x86_64: the CI guest kernels load at physical 16 MiB and do not
# fit the 32 MiB guest the aarch64 docs mention)
bash scripts/blackout-p99.sh 100
# prints p50/p95/p99/max and PASS if p95 <= 30 ms and every guest continued

# the headline: two container hosts, live migration, client-observed blackout
bash scripts/two-host-demo.sh
# prints the beacon analysis: blackout gap and packets lost (expect 0) across
# the host switch, then TWO_HOST_DEMO_DONE
```

What "continued" means: the guest keeps a counter in RAM; after the move the
counter keeps going. If migration had lost memory, the guest would reboot and
restart at 0. The two-host demo additionally proves it from the outside: the
guest streams UDP beacons and a collector shows the sequence numbers never
skip across the migration.

## 4. Run the GUI visualizer

```sh
# first time only: debootstrap a real Debian + XFCE desktop image (~10-20 min,
# needs network). The demo builds the second desktop image automatically.
bash scripts/build-desktop-rootfs.sh

# start everything: daedald in persistent-guest mode, two desktop guests,
# VNC tunnel agents, the websocket gateway, and the web frontend
bash scripts/desktop-migration-demo.sh
```

The script ends by printing a URL like

```
http://localhost:5173/?vnc=<node-id>
```

Open it in your Windows browser. You should see two host cards with a live
XFCE desktop under the host that owns the guest. Click **Migrate**: the edge
between the hosts animates off the real SSE migration events, and the desktop
card moves to the other host -- the same running VM, never rebooted, keeping
its IP and VNC stream across the move.

Useful while it runs:

```sh
curl -s localhost:7040/v1/migrations/guest      # who owns the guest right now
curl -s localhost:7040/v1/metrics               # blackout p50/p95/p99
curl -s localhost:7040/v1/migrations -X POST -d '{}'   # migrate from the CLI
```

## 5. Stop everything

```sh
bash scripts/stop-demo.sh
```

kills daedald, every Firecracker VM, the agents/gateway/dev-server, removes
the podman containers, taps, bridge, and the tmpfs snapshot images (that is
where the ~1 GiB of RAM goes), and prints what it did. Idempotent.

Bigger hammer, from PowerShell: `wsl --shutdown` powers off the whole WSL VM
and returns all of its memory to Windows instantly.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `/dev/kvm` missing in Ubuntu | `wsl --update` then `wsl --shutdown`; check SVM/VT-x in BIOS. Verify with `ls -l /dev/kvm`. |
| `ERROR: ... running from a Windows drive mount` | You are under `/mnt/c`. `git clone` the repo to `~/daedal` and run there. |
| `/dev/userfaultfd` missing (Uffd tests refuse to run) | WSL kernel < 6.1. `wsl --update` then `wsl --shutdown`. The default File backend is unaffected. |
| GUI demo is slow / guests OOM | Give WSL more memory via `.wslconfig` (see step 0), or shrink the desktop guest: `GUEST_MEM_MIB=512 bash scripts/desktop-migration-demo.sh`. |
| port 7040 or 5173 already in use | A previous run is alive: `bash scripts/stop-demo.sh`. |
| `mkfs.ext4`/`debootstrap`/`podman` not found | Run `bash scripts/wsl-provision.sh` (or apt-get install the named package). |
| firecracker build fails at `-lseccomp` | `sudo apt-get install libseccomp-dev` (provision installs it). |
| browser cannot reach `localhost:5173` | Confirm the dev server is up inside WSL (`curl localhost:5173`); if WSL networking is customized (mirrored mode etc.), plain NAT mode is the tested path. |
| blackout numbers differ from the README | Expected: README numbers were measured on Apple-Silicon-under-Lima. Yours come from Ryzen-under-WSL2; steady-state cutover should still be single-digit-to-low-tens of ms. |

## Scope

The PVM (no-hardware-virt) kernel path and the Tier-2 iroh-live H.264 video
path are not covered by this runbook; they carry extra, heavyweight
requirements (custom host kernels; UDP/WebTransport end-to-end) beyond the
core migration + GUI demos above.
