# docker-disk-quota

> Hard disk cap for Docker on Azure Machine Learning compute instances.

Stop a single `docker pull` (or a runaway build) from filling the OS disk and
**corrupting your Azure ML compute instance**.

This gives Docker a hard upper limit it can **never** exceed — without
enabling project quotas, changing the kernel command line, or rebooting.

[`docker_quota.sh`](docker_quota.sh) caps Docker's data-root so a runaway pull
or build can't fill the OS disk.

## Why not a normal disk quota?

On a compute instance, the thing that fills your disk is usually `docker pull`,
which runs as **root**. Kernel user quotas don't restrict root, and ext4/XFS
**project quotas** require the `prjquota` mount option plus a reboot/rescue —
not possible on a locked, already-running instance.

Instead, `docker_quota.sh` backs Docker's data-root (`/var/lib/docker`) with a
fixed-size **ext4 loopback image**:

- **The image's logical size = the cap.** The inner filesystem is only that
  big, so `dockerd` (even as root) and `docker pull` physically cannot write
  more than the cap → *Docker can't exceed a number.*
- **The image is sparse and mounted with `discard`**, so its physical size
  grows only as Docker actually stores data and **shrinks again** when you
  prune/remove images → the space stays shared with the rest of the OS until
  Docker really uses it. This is project-quota-like behavior: a **ceiling, not
  a partition**.

## Persistence (verified on Azure ML)

The script adds an `/etc/fstab` entry for the loopback image. On Azure ML
compute instances the **OS disk is preserved across stop/start**, so the fstab
entry and the image file survive a restart and the cap is re-mounted
automatically at boot — at `local-fs`, **before** `docker.service`. No systemd
unit or compute-instance startup script is required.

> The image is intentionally **never** placed on `/mnt` (the Azure ephemeral
> temp disk), which is wiped when the instance is deallocated. The script
> refuses to do so.

## Quick start

```bash
# Auto: cap Docker at (free space − 5 GiB reserve), space stays shared.
sudo ./docker_quota.sh

# Cap Docker at a fixed 40 GiB.
sudo ./docker_quota.sh --size 40

# Keep at least 10 GiB free on the host.
sudo ./docker_quota.sh --reserve 10

# Undo everything (unmount, remove image + fstab entry, restore data).
sudo ./docker_quota.sh --teardown
```

### Options (`docker_quota.sh`)

| Option | Description |
| --- | --- |
| `--root <path>` | Docker data-root (default: `/var/lib/docker`, or whatever `docker info` reports). |
| `--size <gib>` | The cap in GiB. Default: `auto` = host free space minus reserve. |
| `--reserve <gib>` | Free headroom the cap must always leave on the host (default: `5`). |
| `--preallocate` | Claim the full cap on the host disk up front (partition mode). Default is **sparse** so space stays shared until used. |
| `--teardown` | Undo a previous run and restore the original data-root. |
| `-h`, `--help` | Show help. |

## How it works

1. Stops `docker.service` / `containerd` so the data-root is quiescent.
2. Moves any existing `/var/lib/docker` aside to a timestamped backup.
3. Creates a sparse ext4 loopback image sized to the cap (`-m 0` removes the
   inner 5% root reserve so Docker can use the full cap).
4. Mounts it at the data-root with `loop,rw,noatime,discard`.
5. Restores the previous Docker data into the new mount (`rsync`).
6. Adds an `/etc/fstab` line for persistence and restarts Docker.

The original data is kept at `…/var/lib/docker.bak.<timestamp>` until you
verify the new setup and delete it.

## Verify the cap holds

```bash
docker pull <image>                              # works until the cap is hit
dd if=/dev/zero of=/var/lib/docker/fulltest bs=1M  # should stop at ENOSPC
rm -f /var/lib/docker/fulltest                   # frees it again
```

`df -h /var/lib/docker` should show the total equal to your cap.

## Requirements

- Linux (Ubuntu/Debian, RHEL/Fedora, or openSUSE — the script installs missing
  tools via the detected package manager).
- `root` (run with `sudo`).
- `losetup`, `mkfs.ext4`, `mount`, `rsync` (auto-installed if absent).

## Safety notes

- Always test `--teardown` restores cleanly before relying on this in
  production.
- The cap only protects the Docker data-root; other writers can still fill the
  remaining host space (use `--reserve`).
- Review the script before running it as root.

## License

MIT — see [`LICENSE`](LICENSE) if provided, otherwise use at your own risk.
