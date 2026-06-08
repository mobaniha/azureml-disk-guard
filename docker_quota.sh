#!/usr/bin/env bash
#
# docker_quota.sh
#
# Give Docker a hard upper limit it can NEVER exceed, WITHOUT permanently
# carving that space out of the host disk.
#
# Docker's data-root (e.g. /var/lib/docker) is backed by a fixed-size ext4
# loopback image:
#
#   * The image's LOGICAL size = the cap. The inner filesystem is only that
#     big, so dockerd (even as root) and `docker pull` physically cannot
#     write more than the cap. -> "Docker can't exceed a number."
#
#   * The image is SPARSE and mounted with `discard`, so its PHYSICAL size
#     grows only as Docker actually stores data and SHRINKS again when you
#     remove images/containers. -> the space stays shared/free for the rest
#     of the OS until Docker really uses it. (This is the project-quota-like
#     behavior: a ceiling, not a partition.)
#
# Works WITHOUT project quotas, WITHOUT kernel cmdline changes, WITHOUT a reboot.
#
# PERSISTENCE (verified on an Azure ML Compute Instance):
#     This script adds an /etc/fstab entry for the loopback image. On Azure ML
#     Compute Instances the OS disk is preserved across stop/start, so the
#     fstab entry and the image file survive a restart and the cap is
#     re-mounted automatically at boot (at local-fs, BEFORE docker.service).
#     No systemd unit or compute-instance startup script is required.
#
# Usage:
#     sudo ./docker_quota.sh [options]
#
# Options:
#     --root <path>     Docker data-root (default: /var/lib/docker, or whatever
#                       `docker info` reports).
#     --size <gib>      The cap (max GiB Docker may ever use). Default: auto =
#                       host free space minus reserve.
#     --reserve <gib>   Free headroom the cap must always leave on the host
#                       FS (default: 5). Used to bound 'auto' and to reject an
#                       over-large --size.
#     --preallocate     Claim the full cap on the host disk up front (partition
#                       mode). Default is SPARSE so the space stays shared and
#                       only fills as Docker uses it.
#     --teardown        Undo a previous run: unmount the data-root, remove the
#                       loopback image + fstab entry, and restore the original
#                       data. Use --root to target a non-default path.
#     -h, --help        Show this help.
#
# Examples:
#     sudo ./docker_quota.sh --size 40             # cap Docker at 40 GiB (shared)
#     sudo ./docker_quota.sh                        # auto cap = free - reserve
#     sudo ./docker_quota.sh --reserve 10           # auto, keep >=10 GiB free
#     sudo ./docker_quota.sh --preallocate --size 40  # reserve 40 GiB up front
#     sudo ./docker_quota.sh --teardown             # remove the cap
#
set -euo pipefail

#==============================================================================
# Defaults / arg parsing
#==============================================================================
DATA_ROOT=""
SIZE_ARG="auto"
RESERVE_GIB=5
PREALLOCATE=0
TEARDOWN=0
MOUNT_OPTS="loop,rw,noatime,discard"

usage() { sed -n '2,48p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --root)        DATA_ROOT="${2:-}";   shift 2 ;;
        --size)        SIZE_ARG="${2:-}";    shift 2 ;;
        --reserve)     RESERVE_GIB="${2:-}"; shift 2 ;;
        --preallocate) PREALLOCATE=1;        shift ;;
        --teardown)    TEARDOWN=1;           shift ;;
        -h|--help)     usage 0 ;;
        *) echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

#==============================================================================
# Helpers
#==============================================================================
log()  { printf '[docker_quota] %s\n' "$*"; }
fail() { printf '[docker_quota] ERROR: %s\n' "$*" >&2; exit 1; }

detect_pkg_mgr() {
    if command -v apt-get >/dev/null 2>&1; then echo "apt"; return; fi
    if command -v dnf     >/dev/null 2>&1; then echo "dnf"; return; fi
    if command -v yum     >/dev/null 2>&1; then echo "yum"; return; fi
    if command -v zypper  >/dev/null 2>&1; then echo "zypper"; return; fi
    echo "unknown"
}

install_pkg() {
    local pkg="$1" mgr
    mgr="$(detect_pkg_mgr)"
    log "Installing package '$pkg' via $mgr ..."
    case "$mgr" in
        apt)    DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null
                DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" ;;
        dnf)    dnf install -y "$pkg" ;;
        yum)    yum install -y "$pkg" ;;
        zypper) zypper --non-interactive install "$pkg" ;;
        *)      fail "No supported package manager found to install '$pkg'." ;;
    esac
}

#==============================================================================
# Validation
#==============================================================================
[[ "$(id -u)" -eq 0 ]] || fail "Must be run as root (use sudo)."

for c in df findmnt awk stat; do
    command -v "$c" >/dev/null 2>&1 || fail "Required command not found: $c"
done

if ! [[ "$RESERVE_GIB" =~ ^[0-9]+$ ]] || (( RESERVE_GIB < 1 )); then
    fail "--reserve must be a positive integer (got '$RESERVE_GIB')."
fi

#==============================================================================
# Resolve Docker data-root
#==============================================================================
if [[ -z "$DATA_ROOT" ]]; then
    DATA_ROOT="/var/lib/docker"
fi
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    detected="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
    if [[ -n "$detected" && "$detected" != "$DATA_ROOT" ]]; then
        log "Note: docker reports data-root as '$detected' (overriding '$DATA_ROOT')."
        DATA_ROOT="$detected"
    fi
fi

IMG_FILE="${DATA_ROOT}.img"
BACKUP_DIR="${DATA_ROOT}.bak.$(date +%Y%m%d%H%M%S)"

#==============================================================================
# Service control helpers
#==============================================================================
STOPPED_DOCKER=0
STOPPED_CONTAINERD=0

stop_docker() {
    if systemctl is-active --quiet docker 2>/dev/null; then
        log "Stopping docker.service ..."
        systemctl stop docker.socket 2>/dev/null || true
        systemctl stop docker.service
        STOPPED_DOCKER=1
    fi
    if systemctl is-active --quiet containerd 2>/dev/null; then
        systemctl stop containerd
        STOPPED_CONTAINERD=1
    fi
}

start_docker() {
    if (( STOPPED_CONTAINERD )); then
        log "Starting containerd ..."
        systemctl start containerd
    fi
    if (( STOPPED_DOCKER )); then
        log "Starting docker.service ..."
        systemctl start docker.service
    fi
}

#==============================================================================
# Teardown — undo a previous run
#==============================================================================
if (( TEARDOWN )); then
    log "===== TEARDOWN ====="
    log "Target data-root : $DATA_ROOT"
    log "Image file       : $IMG_FILE"

    stop_docker

    if findmnt -n --target "$DATA_ROOT" | awk '{print $1}' | grep -qx "$DATA_ROOT"; then
        log "Unmounting $DATA_ROOT ..."
        umount "$DATA_ROOT" || fail "Could not unmount $DATA_ROOT (is something using it?)."
    else
        log "$DATA_ROOT is not a separate mount (nothing to unmount)."
    fi

    # Remove the fstab line we added (matches the image path).
    if grep -qsF "$IMG_FILE" /etc/fstab; then
        log "Removing fstab entry for $IMG_FILE ..."
        cp -a /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
        grep -vF "$IMG_FILE" /etc/fstab \
            | grep -v '^# docker data-root capped via loopback image$' > /etc/fstab.new
        mv /etc/fstab.new /etc/fstab
    fi

    # Restore the most recent backup of the original data, if present.
    latest_backup="$(ls -1d "${DATA_ROOT}".bak.* 2>/dev/null | sort | tail -n1 || true)"
    if [[ -n "$latest_backup" && -d "$latest_backup" ]]; then
        if [[ -d "$DATA_ROOT" ]] && [[ -n "$(ls -A "$DATA_ROOT" 2>/dev/null || true)" ]]; then
            log "Data-root '$DATA_ROOT' is not empty; leaving backup at $latest_backup for manual review."
        else
            log "Restoring original data from $latest_backup -> $DATA_ROOT ..."
            rm -rf "$DATA_ROOT"
            mv "$latest_backup" "$DATA_ROOT"
        fi
    fi

    if [[ -e "$IMG_FILE" ]]; then
        log "Removing image file $IMG_FILE ..."
        rm -f "$IMG_FILE"
    fi

    start_docker

    log "Teardown complete. Docker is back on the host filesystem (no cap)."
    df -h "$DATA_ROOT" || true
    exit 0
fi

# Required tools for building/mounting the image
for c in losetup mkfs.ext4 mount blkid rsync; do
    if ! command -v "$c" >/dev/null 2>&1; then
        case "$c" in
            mkfs.ext4|blkid) install_pkg e2fsprogs ;;
            losetup|mount)   install_pkg util-linux ;;
            rsync)           install_pkg rsync ;;
        esac
    fi
done

mkdir -p "$(dirname "$IMG_FILE")"
HOST_MOUNT="$(findmnt -n -o TARGET --target "$(dirname "$IMG_FILE")")"

if [[ "$HOST_MOUNT" == "/mnt" ]]; then
    fail "Refusing to place image on /mnt (Azure ephemeral disk — wiped on deallocate)."
fi

# Idempotent: if the data-root is already its own mount, do nothing.
if findmnt -n --target "$DATA_ROOT" | awk '{print $1}' | grep -qx "$DATA_ROOT"; then
    log "'$DATA_ROOT' is already a dedicated mount. Nothing to do."
    log "(Run with --teardown first if you want to recreate it at a new size.)"
    findmnt "$DATA_ROOT" || true
    exit 0
fi

# Boot re-apply: if the image already exists but isn't mounted (e.g. the fstab
# entry was removed, or you're running the script manually before the boot
# mount happened), just mount the existing image and exit — this preserves any
# Docker data inside it and is safe to run at boot.
if [[ -e "$IMG_FILE" ]]; then
    log "Existing image found at $IMG_FILE but $DATA_ROOT is not mounted."
    stop_docker
    mkdir -p "$DATA_ROOT"
    log "Re-mounting existing image (opts=$MOUNT_OPTS) ..."
    mount -o "$MOUNT_OPTS" "$IMG_FILE" "$DATA_ROOT"
    start_docker
    log "Re-mounted existing capped image. Done."
    df -h "$DATA_ROOT" || true
    exit 0
fi

#==============================================================================
# Compute image size = free - reserve  (guaranteeing the reserve stays free)
#==============================================================================
HOST_FREE_KB="$(df -P -k "$HOST_MOUNT" | awk 'NR==2 {print $4}')"
HOST_FREE_GIB=$(( HOST_FREE_KB / 1024 / 1024 ))

if [[ "$SIZE_ARG" == "auto" ]]; then
    (( HOST_FREE_GIB > RESERVE_GIB + 1 )) \
        || fail "Not enough free space on $HOST_MOUNT (${HOST_FREE_GIB} GiB free, reserve ${RESERVE_GIB} GiB)."
    SIZE_GIB=$(( HOST_FREE_GIB - RESERVE_GIB ))
else
    [[ "$SIZE_ARG" =~ ^[0-9]+$ ]] && (( SIZE_ARG >= 1 )) \
        || fail "--size must be a positive integer or 'auto' (got '$SIZE_ARG')."
    SIZE_GIB="$SIZE_ARG"
    # Never let an explicit size eat into the reserve.
    if (( SIZE_GIB > HOST_FREE_GIB - RESERVE_GIB )); then
        fail "--size ${SIZE_GIB} GiB would leave less than ${RESERVE_GIB} GiB free (only ${HOST_FREE_GIB} GiB free now)."
    fi
fi

log "Host mount        : $HOST_MOUNT (${HOST_FREE_GIB} GiB free)"
log "Docker data-root  : $DATA_ROOT"
log "Image file        : $IMG_FILE"
log "Cap (max usable)  : ${SIZE_GIB} GiB"
log "Reserve kept free : ${RESERVE_GIB} GiB"
log "Mode              : $([[ $PREALLOCATE -eq 1 ]] && echo 'preallocated (partition; space claimed up front)' || echo 'sparse + discard (quota; space stays shared until used)')"

#==============================================================================
# Stop Docker so the data-root is quiescent
#==============================================================================
stop_docker

#==============================================================================
# Move existing data aside
#==============================================================================
if [[ -d "$DATA_ROOT" ]] && [[ -n "$(ls -A "$DATA_ROOT" 2>/dev/null || true)" ]]; then
    log "Moving existing data: $DATA_ROOT -> $BACKUP_DIR"
    mv "$DATA_ROOT" "$BACKUP_DIR"
fi
mkdir -p "$DATA_ROOT"

#==============================================================================
# Create the image
#==============================================================================
if [[ -e "$IMG_FILE" ]]; then
    fail "Image file already exists: $IMG_FILE (refusing to overwrite)."
fi

if (( PREALLOCATE )); then
    log "Allocating ${SIZE_GIB} GiB image (fully preallocated; this may take a few minutes) ..."
    # Try a fast physical preallocation first; fall back to zero-fill.
    if ! fallocate -l "${SIZE_GIB}G" "$IMG_FILE" 2>/dev/null; then
        : > "$IMG_FILE"
    fi
    # Zero-fill to guarantee the host physically accounts for the reservation,
    # even on filesystems where fallocate leaves holes. oflag=direct bypasses
    # the page cache; conv=notrunc keeps any fallocate'd extents.
    dd if=/dev/zero of="$IMG_FILE" bs=1M count=$(( SIZE_GIB * 1024 )) \
       conv=notrunc oflag=direct status=progress 2>/dev/null \
       || dd if=/dev/zero of="$IMG_FILE" bs=1M count=$(( SIZE_GIB * 1024 )) \
             conv=notrunc status=progress
    sync

    # Verify the file physically consumes (close to) its logical size.
    apparent=$(stat -c %s "$IMG_FILE")
    physical=$(( $(stat -c %b "$IMG_FILE") * $(stat -c %B "$IMG_FILE") ))
    log "Image apparent=$(( apparent / 1024 / 1024 )) MiB, physical=$(( physical / 1024 / 1024 )) MiB"
    if (( physical < apparent * 95 / 100 )); then
        fail "Image is still sparse after preallocation; host reservation not guaranteed. Aborting."
    fi
else
    log "Allocating ${SIZE_GIB} GiB image (sparse) ..."
    # Use truncate (NOT fallocate) so the file is genuinely sparse: it reserves
    # the logical address space (the cap) but consumes ~0 host blocks until
    # Docker actually writes data into it.
    truncate -s "${SIZE_GIB}G" "$IMG_FILE"
fi
chmod 600 "$IMG_FILE"

#==============================================================================
# Format + mount
#==============================================================================
log "Creating ext4 inside the image ..."
# -m 0  : remove the inner 5% root-reserve so Docker can use the full cap.
# lazy_*: don't eagerly write inode/journal tables -> keeps the image sparse
#         so the host only loses space as Docker actually writes data.
mkfs.ext4 -q -F -m 0 -E lazy_itable_init=1,lazy_journal_init=1 \
    -L docker_data "$IMG_FILE"

log "Mounting $IMG_FILE -> $DATA_ROOT (loop, opts=$MOUNT_OPTS) ..."
# 'discard' returns freed blocks to the host image when Docker removes data,
# so the cap behaves like a quota (ceiling) rather than a fixed partition.
mount -o "$MOUNT_OPTS" "$IMG_FILE" "$DATA_ROOT"

#==============================================================================
# Restore previous data
#==============================================================================
if [[ -d "$BACKUP_DIR" ]]; then
    log "Restoring previous docker data into new mount ..."
    rsync -aHAX --numeric-ids "$BACKUP_DIR"/ "$DATA_ROOT"/
    log "Old data preserved at: $BACKUP_DIR  (delete after verifying)"
fi

#==============================================================================
# Persist across reboot
#==============================================================================
FSTAB_LINE="$IMG_FILE  $DATA_ROOT  ext4  $MOUNT_OPTS  0 0"
if ! grep -qsF "$IMG_FILE" /etc/fstab; then
    log "Adding fstab entry for persistence ..."
    cp -a /etc/fstab "/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
    printf '\n# docker data-root capped via loopback image\n%s\n' "$FSTAB_LINE" >> /etc/fstab
fi

#==============================================================================
# Restart services
#==============================================================================
start_docker

log "------------------------------------------------------------"
log "Done. Docker at '$DATA_ROOT' can use AT MOST ${SIZE_GIB} GiB."
if (( PREALLOCATE )); then
    log "Mode: preallocated — the ${SIZE_GIB} GiB is claimed on the host now."
else
    log "Mode: sparse+discard — host space stays shared; it only fills as"
    log "      Docker stores data and is returned when you prune/remove images."
fi
log "Host '$HOST_MOUNT' keeps >= ${RESERVE_GIB} GiB free headroom."
echo
log "Docker data-root (note the ${SIZE_GIB}G total = the cap):"
df -h "$DATA_ROOT" || true
echo
log "Host filesystem:"
df -h "$HOST_MOUNT" || true
log "------------------------------------------------------------"
log "Validate the cap holds:"
log "  docker pull <image>            # works until the cap is hit"
log "  dd if=/dev/zero of=$DATA_ROOT/fulltest bs=1M  # should stop at ENOSPC"
log "  rm -f $DATA_ROOT/fulltest      # frees it again"
log "------------------------------------------------------------"