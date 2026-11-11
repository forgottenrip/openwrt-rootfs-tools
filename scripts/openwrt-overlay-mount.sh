#!/usr/bin/env bash
#
# openwrt-overlay-mount.sh
#
# Mount the writable overlay (ext4 or f2fs) that lives inside an OpenWrt
# SquashFS partition, so files can be inspected or modified from a Linux PC.
#
# Modes:
#   (default)     mount the overlay read-write
#   -u/--unmount  unmount and detach the loop device
#   -s/--status   show current state
#
# The loop offset is auto-detected from the SquashFS superblock + a bounded
# magic scan, so the same script works for any OpenWrt SD card layout.
#
set -euo pipefail

DEFAULT_MOUNTPOINT="/mnt/openwrt-overlay"
STATE_FILE="/run/openwrt-overlay-mount.state"
SCAN_MB=32

DEV=""
MOUNTPOINT="$DEFAULT_MOUNTPOINT"
READ_ONLY=0
UNMOUNT=0
STATUS=0
DRY_RUN=0

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '\033[1;36m[DRY]\033[0m ' >&2
        printf '%q ' "$@" >&2
        echo >&2
    else
        "$@"
    fi
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] <disk-or-partition>

Mount, unmount, or inspect the ext4/f2fs overlay living inside an OpenWrt
SquashFS partition. The overlay's offset is detected automatically.

Commands:
  (default)              mount overlay read-write
  -u, --unmount          unmount and detach loop device
  -s, --status           show current mount state

Mount options:
  -m, --mountpoint DIR   mount point (default: $DEFAULT_MOUNTPOINT)
  -r, --read-only        mount read-only (safe for inspection)
  -n, --dry-run          print what would happen, change nothing
  -h, --help             show this help

Examples:
  sudo $(basename "$0") /dev/sdb
  sudo $(basename "$0") -r /dev/sdb2
  sudo $(basename "$0") --unmount
  sudo $(basename "$0") --status
EOF
}

# ---------------------------------------------------------------- args
while [ $# -gt 0 ]; do
    case "$1" in
        -u|--unmount)      UNMOUNT=1; shift ;;
        -s|--status)       STATUS=1; shift ;;
        -m|--mountpoint)   MOUNTPOINT=$2; shift 2 ;;
        -r|--read-only)    READ_ONLY=1; shift ;;
        -n|--dry-run)      DRY_RUN=1; shift ;;
        -h|--help)         usage; exit 0 ;;
        --)                shift; [ $# -gt 0 ] && { DEV=$1; shift; }; break ;;
        -*)                usage; exit 1 ;;
        *)                 DEV=$1; shift ;;
    esac
done

# ---------------------------------------------------------------- state helpers
is_loop_attached() {
    losetup -a 2>/dev/null | grep -q "^$1:"
}

load_state() {
    # shellcheck disable=SC1090
    . "$STATE_FILE"
}

# ---------------------------------------------------------------- status
if [ "$STATUS" -eq 1 ]; then
    if [ ! -f "$STATE_FILE" ]; then
        log "no overlay mount recorded"
        exit 0
    fi
    load_state
    if [ -d "$MOUNTPOINT" ] && mountpoint -q "$MOUNTPOINT" 2>/dev/null; then
        ok "mounted at $MOUNTPOINT"
        findmnt -o TARGET,SOURCE,FSTYPE,SIZE,USED,AVAIL,USE%,OPTIONS "$MOUNTPOINT" 2>/dev/null \
            || df -h "$MOUNTPOINT"
    else
        warn "state file exists but $MOUNTPOINT is NOT mounted"
        warn "state: loop=${LOOP_DEV:-?}  offset=${OVERLAY_OFFSET:-?}  type=${OVERLAY_TYPE:-?}"
        warn "run '$0 --unmount' to clean up"
    fi
    exit 0
fi

# ---------------------------------------------------------------- unmount
if [ "$UNMOUNT" -eq 1 ]; then
    if [ ! -f "$STATE_FILE" ]; then
        # allow direct target if user passes a mountpoint
        if [ -n "$DEV" ] && [ -d "$DEV" ] && mountpoint -q "$DEV" 2>/dev/null; then
            run umount "$DEV"
            ok "unmounted $DEV"
            exit 0
        fi
        err "nothing to unmount (no state file at $STATE_FILE)"
    fi
    load_state
    if [ -d "$MOUNTPOINT" ] && mountpoint -q "$MOUNTPOINT" 2>/dev/null; then
        log "syncing filesystem…"
        run sync
        log "unmounting $MOUNTPOINT"
        run umount "$MOUNTPOINT"
        ok "unmounted"
    else
        warn "$MOUNTPOINT was not mounted; continuing cleanup"
    fi
    if [ -n "${LOOP_DEV:-}" ] && is_loop_attached "$LOOP_DEV"; then
        log "detaching loop $LOOP_DEV"
        run losetup -d "$LOOP_DEV"
        ok "detached"
    fi
    run rm -f "$STATE_FILE"
    ok "done — safe to remove the SD card"
    exit 0
fi

# ---------------------------------------------------------------- mount
[ -n "$DEV" ] || { usage; exit 1; }
[ "$EUID" -eq 0 ] || err "must run as root"
[ -b "$DEV" ] || err "not a block device: $DEV"

# existing state? fail if actually mounted, else clean stale state
if [ -f "$STATE_FILE" ]; then
    load_state
    if [ -d "$MOUNTPOINT" ] && mountpoint -q "$MOUNTPOINT" 2>/dev/null; then
        err "already mounted at $MOUNTPOINT; run '$0 --unmount' first"
    fi
    warn "cleaning stale state file"
    [ -n "${LOOP_DEV:-}" ] && is_loop_attached "$LOOP_DEV" && losetup -d "$LOOP_DEV" 2>/dev/null || true
    rm -f "$STATE_FILE"
fi

# find the squashfs partition
if [ "$(lsblk -dno TYPE "$DEV" 2>/dev/null)" = "disk" ]; then
    ROOTFS_PART=""
    while IFS= read -r part; do
        [ -b "$part" ] || continue
        m=$(dd if="$part" bs=1 count=4 2>/dev/null || true)
        if [ "$m" = "hsqs" ] || [ "$m" = "sqsh" ]; then
            ROOTFS_PART=$part
            break
        fi
    done < <(lsblk -lnpo NAME "$DEV" 2>/dev/null | tail -n +2)
    [ -n "$ROOTFS_PART" ] || err "no squashfs partition found on $DEV"
else
    ROOTFS_PART=$DEV
    m=$(dd if="$ROOTFS_PART" bs=1 count=4 2>/dev/null || true)
    [ "$m" = "hsqs" ] || [ "$m" = "sqsh" ] || err "$DEV is not a squashfs partition"
fi
log "squashfs partition: $ROOTFS_PART"

if findmnt -rn -S "$ROOTFS_PART" >/dev/null 2>&1; then
    err "$ROOTFS_PART is already mounted; unmount it first"
fi

# read squashfs bytes_used at offset 40
SQ_SIZE=$(dd if="$ROOTFS_PART" bs=1 skip=40 count=8 2>/dev/null | od -An -tu8 | tr -d ' \n')
[ -n "${SQ_SIZE:-}" ] && [ "$SQ_SIZE" -gt 0 ] || err "cannot read squashfs superblock"
log "squashfs size: $SQ_SIZE bytes"

# scan a bounded window after the squashfs for overlay magic
SS=$(blockdev --getss "$ROOTFS_PART")
SCAN_START=$(( SQ_SIZE / SS * SS ))
SCAN_SECTORS=$(( SCAN_MB * 1024 * 1024 / SS ))
TMP_DUMP=$(mktemp)
trap 'rm -f "$TMP_DUMP"' EXIT
dd if="$ROOTFS_PART" bs="$SS" skip=$(( SCAN_START / SS )) count="$SCAN_SECTORS" of="$TMP_DUMP" 2>/dev/null || true

OVERLAY_OFFSET=""; OVERLAY_TYPE=""; OVERLAY_LOOP=""

# ext4-family magic 0x53ef sits at FS_start+0x438
for pos in $(LC_ALL=C grep -aob $'\x53\xef' "$TMP_DUMP" 2>/dev/null | cut -d: -f1 || true); do
    fs_start=$(( SCAN_START + pos - 0x438 ))
    [ "$fs_start" -lt "$SQ_SIZE" ] && continue
    [ $((fs_start % 512)) -ne 0 ] && continue
    loop=$(losetup --find --show --offset="$fs_start" "$ROOTFS_PART" 2>/dev/null) || continue
    fstype=$(blkid -s TYPE -o value "$loop" 2>/dev/null || true)
    case "$fstype" in
        ext2|ext3|ext4)
            OVERLAY_OFFSET=$fs_start; OVERLAY_TYPE=$fstype; OVERLAY_LOOP=$loop
            break ;;
    esac
    losetup -d "$loop" >/dev/null 2>&1 || true
done

# f2fs magic 0xf2f52010 sits at FS_start+0x400
if [ -z "$OVERLAY_OFFSET" ]; then
    for pos in $(LC_ALL=C grep -aob $'\x10\x20\xf5\xf2' "$TMP_DUMP" 2>/dev/null | cut -d: -f1 || true); do
        fs_start=$(( SCAN_START + pos - 0x400 ))
        [ "$fs_start" -lt "$SQ_SIZE" ] && continue
        [ $((fs_start % 512)) -ne 0 ] && continue
        loop=$(losetup --find --show --offset="$fs_start" "$ROOTFS_PART" 2>/dev/null) || continue
        fstype=$(blkid -s TYPE -o value "$loop" 2>/dev/null || true)
        if [ "$fstype" = "f2fs" ]; then
            OVERLAY_OFFSET=$fs_start; OVERLAY_TYPE=f2fs; OVERLAY_LOOP=$loop
            break
        fi
        losetup -d "$loop" >/dev/null 2>&1 || true
    done
fi

if [ -z "$OVERLAY_LOOP" ]; then
    err "no ext4/f2fs overlay found within ${SCAN_MB}MB after squashfs on $ROOTFS_PART"
fi
log "overlay: $OVERLAY_TYPE @ offset $OVERLAY_OFFSET (loop $OVERLAY_LOOP)"

# mount
mkdir -p "$MOUNTPOINT"
if [ -d "$MOUNTPOINT" ] && [ -n "$(ls -A "$MOUNTPOINT" 2>/dev/null || true)" ]; then
    warn "$MOUNTPOINT is not empty; existing files will be shadowed by the mount"
fi

OPTS="rw"
[ "$READ_ONLY" -eq 1 ] && OPTS="ro"

if [ "$DRY_RUN" -eq 1 ]; then
    log "[DRY] mount -t $OVERLAY_TYPE -o $OPTS $OVERLAY_LOOP $MOUNTPOINT"
    losetup -d "$OVERLAY_LOOP" 2>/dev/null || true
    exit 0
fi

if ! mount -t "$OVERLAY_TYPE" -o "$OPTS" "$OVERLAY_LOOP" "$MOUNTPOINT"; then
    losetup -d "$OVERLAY_LOOP" 2>/dev/null || true
    cat >&2 <<EOF

Mount failed. Common causes:
  - Overlay is dirty from an unclean shutdown. Try:
      fsck.$OVERLAY_TYPE -f $OVERLAY_LOOP
    …then retry, or mount read-only:
      sudo $0 -r $DEV
  - Overlay is already mounted somewhere else.
  - You are not root.

EOF
    exit 1
fi

# persist state for --unmount / --status
cat > "$STATE_FILE" <<EOF
LOOP_DEV="$OVERLAY_LOOP"
MOUNTPOINT="$MOUNTPOINT"
ROOTFS_PART="$ROOTFS_PART"
OVERLAY_OFFSET="$OVERLAY_OFFSET"
OVERLAY_TYPE="$OVERLAY_TYPE"
EOF
chmod 600 "$STATE_FILE"

ok "mounted $OVERLAY_TYPE overlay ($OPTS) at $MOUNTPOINT"
findmnt -o TARGET,SOURCE,FSTYPE,SIZE,USED,AVAIL,USE%,OPTIONS "$MOUNTPOINT" 2>/dev/null \
    || df -h "$MOUNTPOINT"

cat <<EOF

You can now modify files under:
  $MOUNTPOINT

When finished, flush writes and unmount cleanly:
  sudo $0 --unmount

Do NOT remove the SD card while mounted — writes may be lost or the
filesystem may become dirty.
EOF
