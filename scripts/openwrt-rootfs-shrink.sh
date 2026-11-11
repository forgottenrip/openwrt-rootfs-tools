#!/usr/bin/env bash
#
# openwrt-rootfs-shrink.sh
#
# Shrink an OpenWrt SD card's rootfs partition on a Linux PC.
# Handles:
#   SquashFS + ext4 overlay   -> in-place shrink via resize2fs
#   SquashFS + f2fs overlay   -> backup, recreate, restore (requires --allow-f2fs-rebuild)
#   SquashFS-only             -> partition-only shrink, no filesystem work
#
# Does NOT create new partitions. The freed space stays unallocated at the end.
#
set -euo pipefail

# ---------------------------------------------------------------- defaults
TARGET_SIZE="4G"
DRY_RUN=0
ASSUME_YES=0
BACKUP_IMAGE=""
ALLOW_F2FS_REBUILD=0
DEV=""
SCAN_MB=32

# ---------------------------------------------------------------- output
log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] <disk-device>

Shrink the OpenWrt rootfs partition on an SD card. Automatically detects
SquashFS + ext4/f2fs overlay layout. Never creates new partitions.

Options:
  -s, --size SIZE           Target partition size (default: 4G).
  -b, --backup-image FILE   Write a full-disk image to FILE before changes.
  -y, --yes                 Skip confirmation prompts.
  -n, --dry-run             Show what would happen, change nothing.
      --allow-f2fs-rebuild  Allow backup+rebuild+restore for f2fs overlays.
  -h, --help                Show this help.

Examples:
  sudo $(basename "$0") --size 4G --backup-image /root/sd.img /dev/sdb
  sudo $(basename "$0") -n --size 4G /dev/sdb
EOF
}

# ---------------------------------------------------------------- helpers
run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '\033[1;36m[DRY]\033[0m ' >&2
        printf '%q ' "$@" >&2
        echo >&2
    else
        "$@"
    fi
}

confirm() {
    [ "$ASSUME_YES" -eq 1 ] && return 0
    local ans
    read -r -p "$1 [y/N] " ans || true
    case "${ans:-}" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

size_to_sectors() {
    local spec=$1 ss=$2 num mult=1 bytes
    case "$spec" in
        *[gG]) num=${spec%[gG]}; mult=$((1024*1024*1024)) ;;
        *[mM]) num=${spec%[mM]}; mult=$((1024*1024)) ;;
        *[kK]) num=${spec%[kK]}; mult=$((1024)) ;;
        *)     num=$spec ;;
    esac
    bytes=$(awk -v n="$num" -v m="$mult" 'BEGIN{printf "%.0f", n*m}')
    echo $(( bytes / ss ))
}

human() { numfmt --to=iec "$1" 2>/dev/null || echo "$1 bytes"; }

CLEANUP=()
cleanup_all() {
    local cmd
    for cmd in ${CLEANUP[@]+"${CLEANUP[@]}"}; do eval "$cmd" >/dev/null 2>&1 || true; done
}
trap cleanup_all EXIT
cleanup_add() { CLEANUP+=("$1"); }

# ---------------------------------------------------------------- args
while [ $# -gt 0 ]; do
    case "$1" in
        -s|--size)             TARGET_SIZE=$2; shift 2 ;;
        -b|--backup-image)     BACKUP_IMAGE=$2; shift 2 ;;
        -y|--yes)              ASSUME_YES=1; shift ;;
        -n|--dry-run)          DRY_RUN=1; shift ;;
        --allow-f2fs-rebuild)  ALLOW_F2FS_REBUILD=1; shift ;;
        -h|--help)             usage; exit 0 ;;
        --)                    shift; [ $# -gt 0 ] && { DEV=$1; shift; }; break ;;
        -*)                    usage; exit 1 ;;
        *)                     DEV=$1; shift ;;
    esac
done
[ -n "$DEV" ] || { usage; exit 1; }

# ---------------------------------------------------------------- Phase 0
log "Preflight"

[ "$EUID" -eq 0 ] || err "must run as root"
[ -b "$DEV" ] || err "$DEV is not a block device"
[ "$(lsblk -d -no TYPE "$DEV" 2>/dev/null || echo x)" = "disk" ] \
    || err "$DEV is not a whole disk (use e.g. /dev/sdb, not /dev/sdb2)"

# mounted?
MOUNTED=$(lsblk -rn -o NAME,MOUNTPOINT "$DEV" | awk '$2!=""{print $1" -> "$2}')
if [ -n "$MOUNTED" ]; then
    err "partitions of $DEV are mounted:\n$MOUNTED\nUnmount them first."
fi

# loops?
LOOPS=$(losetup -a 2>/dev/null | grep -E "$(basename "$DEV")[0-9]+" | cut -d: -f1 || true)
if [ -n "$LOOPS" ]; then
    warn "Attached loop devices:"
    echo "$LOOPS" >&2
    confirm "Detach them?" || exit 1
    for l in $LOOPS; do run losetup -d "$l" || true; done
fi

SS=$(blockdev --getss "$DEV")
log "device $DEV, sector size $SS, size $(human "$(blockdev --getsize64 "$DEV")")"
log "current partition table:"
sfdisk --dump "$DEV" >&2

# ---------------------------------------------------------------- backup
if [ -n "$BACKUP_IMAGE" ]; then
    [ -e "$BACKUP_IMAGE" ] && { warn "file exists: $BACKUP_IMAGE"; confirm "Overwrite?" || exit 1; }
    log "writing full-disk backup to $BACKUP_IMAGE"
    if [ "$DRY_RUN" -eq 0 ]; then
        dd if="$DEV" of="$BACKUP_IMAGE" bs=4M status=progress conv=fsync
        sync
        ok "backup: $(ls -lh "$BACKUP_IMAGE")"
    fi
else
    warn "no --backup-image supplied; a full-disk image is the only reliable recovery."
    confirm "Proceed without a backup?" || exit 1
fi

# ---------------------------------------------------------------- Phase 1
log "detecting layout"

ROOTFS_PART=""; ROOTFS_NUM=""; ROOTFS_START_SECTOR=0; ROOTFS_SIZE_SECTOR=0
while IFS= read -r line; do
    [[ $line == /dev/*\ :\ start=* ]] || continue
    cand=$(echo "$line" | cut -d: -f1 | tr -d ' ')
    start_s=$(echo "$line" | grep -oE 'start=\s*[0-9]+' | grep -oE '[0-9]+')
    size_s=$(echo "$line"  | grep -oE 'size=\s*[0-9]+'  | grep -oE '[0-9]+')
    magic=$(dd if="$cand" bs=1 count=4 2>/dev/null || true)
    if [ "$magic" = "hsqs" ] || [ "$magic" = "sqsh" ]; then
        ROOTFS_PART=$cand
        ROOTFS_NUM=$(echo "$cand" | sed -E 's|^[^0-9]+([0-9]+)$|\1|')
        ROOTFS_START_SECTOR=$start_s
        ROOTFS_SIZE_SECTOR=$size_s
        break
    fi
done < <(sfdisk --dump "$DEV" 2>/dev/null | grep '^/dev/')

[ -n "$ROOTFS_PART" ] || err "no SquashFS partition found on $DEV"
ROOTFS_START_BYTES=$((ROOTFS_START_SECTOR * SS))
ROOTFS_SIZE_BYTES=$((ROOTFS_SIZE_SECTOR  * SS))
log "rootfs: $ROOTFS_PART, start sector $ROOTFS_START_SECTOR, size $(human "$ROOTFS_SIZE_BYTES")"

SQ_SIZE=$(dd if="$ROOTFS_PART" bs=1 skip=40 count=8 2>/dev/null | od -An -tu8 | tr -d ' \n')
[ -n "${SQ_SIZE:-}" ] && [ "$SQ_SIZE" -gt 0 ] || err "cannot read SquashFS superblock"
[ "$SQ_SIZE" -lt "$ROOTFS_SIZE_BYTES" ] || err "SquashFS reports larger than partition"
log "squashfs bytes_used: $SQ_SIZE ($(human "$SQ_SIZE"))"

# scan for overlay
log "scanning ${SCAN_MB}MB after SquashFS for overlay…"
SCAN_START=$(( SQ_SIZE / SS * SS ))
SCAN_SECTORS=$(( SCAN_MB * 1024 * 1024 / SS ))
TMP_DUMP=$(mktemp); cleanup_add "rm -f '$TMP_DUMP'"
dd if="$ROOTFS_PART" bs="$SS" skip=$(( SCAN_START / SS )) count="$SCAN_SECTORS" of="$TMP_DUMP" 2>/dev/null || true

OVERLAY_OFFSET=""; OVERLAY_TYPE="none"; OVERLAY_LOOP=""

# ext4-family magic is 0x53ef at FS_start+0x438
for pos in $(LC_ALL=C grep -aob $'\x53\xef' "$TMP_DUMP" 2>/dev/null | cut -d: -f1 || true); do
    fs_start=$(( SCAN_START + pos - 0x438 ))
    [ "$fs_start" -lt "$SQ_SIZE" ] && continue
    [ $((fs_start % 512)) -ne 0 ] && continue
    loop=$(losetup --find --show --offset="$fs_start" "$ROOTFS_PART" 2>/dev/null) || continue
    if blkid "$loop" 2>/dev/null | grep -qE 'TYPE="ext[234]"'; then
        OVERLAY_OFFSET=$fs_start; OVERLAY_TYPE=ext4; OVERLAY_LOOP=$loop
        ok "ext4-family overlay at offset $fs_start"; break
    fi
    losetup -d "$loop" >/dev/null 2>&1 || true
done

# f2fs magic is 0xF2F52010 at FS_start+0x400
if [ -z "$OVERLAY_OFFSET" ]; then
    for pos in $(LC_ALL=C grep -aob $'\x10\x20\xf5\xf2' "$TMP_DUMP" 2>/dev/null | cut -d: -f1 || true); do
        fs_start=$(( SCAN_START + pos - 0x400 ))
        [ "$fs_start" -lt "$SQ_SIZE" ] && continue
        [ $((fs_start % 512)) -ne 0 ] && continue
        loop=$(losetup --find --show --offset="$fs_start" "$ROOTFS_PART" 2>/dev/null) || continue
        if blkid "$loop" 2>/dev/null | grep -q 'TYPE="f2fs"'; then
            OVERLAY_OFFSET=$fs_start; OVERLAY_TYPE=f2fs; OVERLAY_LOOP=$loop
            ok "f2fs overlay at offset $fs_start"; break
        fi
        losetup -d "$loop" >/dev/null 2>&1 || true
    done
fi

[ -n "$OVERLAY_LOOP" ] && cleanup_add "losetup -d '$OVERLAY_LOOP'"

if [ "$OVERLAY_TYPE" = "none" ]; then
    warn "no overlay found within ${SCAN_MB}MB after SquashFS."
    warn "only the partition entry will be shrunk; no filesystem will be touched."
    confirm "Continue?" || exit 1
fi

# ---------------------------------------------------------------- Phase 2
log "computing targets"
TARGET_SECTORS=$(size_to_sectors "$TARGET_SIZE" "$SS")
TARGET_BYTES=$((TARGET_SECTORS * SS))
log "target: $TARGET_SIZE = $TARGET_BYTES bytes = $TARGET_SECTORS sectors"

[ "$TARGET_BYTES" -lt "$ROOTFS_SIZE_BYTES" ] || err "target is not smaller than current partition"
[ "$TARGET_BYTES" -gt "$SQ_SIZE" ]           || err "target is smaller than SquashFS itself"
if [ "$OVERLAY_TYPE" != "none" ] && [ "$OVERLAY_OFFSET" -ge "$TARGET_BYTES" ]; then
    err "target size is smaller than overlay offset ($OVERLAY_OFFSET)"
fi
if [ "$OVERLAY_TYPE" = "none" ] && [ "$TARGET_BYTES" -lt $((SQ_SIZE + 1048576)) ]; then
    err "target must be >= squashfs size + 1MiB"
fi

if [ "$OVERLAY_TYPE" = "ext4" ]; then
    # precheck without modifying
    BLOCK_SIZE=$(dumpe2fs -h "$OVERLAY_LOOP" 2>/dev/null | awk -F: '/^Block size:/{gsub(/ /,"",$2);print $2}')
    CURRENT_BLOCKS=$(dumpe2fs -h "$OVERLAY_LOOP" 2>/dev/null | awk -F: '/^Block count:/{gsub(/ /,"",$2);print $2}')
    BLOCK_SIZE=${BLOCK_SIZE:-4096}; CURRENT_BLOCKS=${CURRENT_BLOCKS:-0}
    AVAIL_BYTES=$(( TARGET_BYTES - OVERLAY_OFFSET ))
    MAX_BLOCKS=$(( AVAIL_BYTES / BLOCK_SIZE ))
    TARGET_BLOCKS=$(( MAX_BLOCKS * 99 / 100 ))
    log "ext4: block size $BLOCK_SIZE, current $CURRENT_BLOCKS blocks, target max $MAX_BLOCKS, will shrink to $TARGET_BLOCKS"
fi

# plan + confirmation
log "plan:"
[ "$OVERLAY_TYPE" != "none" ] && log "  1. shrink $OVERLAY_TYPE overlay at offset $OVERLAY_OFFSET"
log "  2. shrink $ROOTFS_PART to $(human "$TARGET_BYTES") ($TARGET_SECTORS sectors)"
log "  3. verify squashfs + overlay"
confirm "Execute this plan?" || exit 1

# ---------------------------------------------------------------- Phase 3
if [ "$OVERLAY_TYPE" = "ext4" ]; then
    log "shrinking ext4 overlay"
    ec=0
    if [ "$DRY_RUN" -eq 0 ]; then
        log "  e2fsck -f (this may take a while)…"
        e2fsck -f -y "$OVERLAY_LOOP" || ec=$?
        [ $ec -le 1 ] || err "e2fsck returned $ec; aborting"
    fi

    MIN_BLOCKS=$(resize2fs -P "$OVERLAY_LOOP" 2>/dev/null | awk '/minimum size/{print $NF}' || true)
    MIN_BLOCKS=${MIN_BLOCKS:-0}
    log "  minimum required blocks: $MIN_BLOCKS"
    [ "$TARGET_BLOCKS" -ge "$MIN_BLOCKS" ] \
        || err "cannot shrink to $TARGET_BLOCKS blocks; minimum is $MIN_BLOCKS; increase --size"

    if [ "$TARGET_BLOCKS" -lt "$CURRENT_BLOCKS" ]; then
        if [ "$DRY_RUN" -eq 0 ]; then
            log "  resize2fs $OVERLAY_LOOP $TARGET_BLOCKS (minutes)…"
            if ! resize2fs "$OVERLAY_LOOP" "$TARGET_BLOCKS"; then
                err "resize2fs failed; restore from backup"
            fi
            NEW_BLOCKS=$(dumpe2fs -h "$OVERLAY_LOOP" 2>/dev/null | awk -F: '/^Block count:/{gsub(/ /,"",$2);print $2}')
            ok "  ext4 now $NEW_BLOCKS blocks (was $CURRENT_BLOCKS)"
            [ $((NEW_BLOCKS * BLOCK_SIZE)) -le "$AVAIL_BYTES" ] \
                || err "resize2fs result exceeds target space"
        else
            log "  [DRY] resize2fs $OVERLAY_LOOP $TARGET_BLOCKS"
        fi
    else
        warn "  ext4 already fits in target; skipping resize2fs"
    fi

    losetup -d "$OVERLAY_LOOP" 2>/dev/null || true
    OVERLAY_LOOP=""

elif [ "$OVERLAY_TYPE" = "f2fs" ]; then
    [ "$ALLOW_F2FS_REBUILD" -eq 1 ] \
        || err "f2fs overlay detected; f2fs cannot be shrunk in place. rerun with --allow-f2fs-rebuild"
    log "f2fs overlay: backup / rebuild / restore"

    MNT=$(mktemp -d); cleanup_add "rm -rf '$MNT'"
    TARBALL=$(mktemp --suffix=.f2fs-backup.tar.gz); cleanup_add "rm -f '$TARBALL'"

    log "  backing up overlay to $TARBALL"
    if [ "$DRY_RUN" -eq 0 ]; then
        mount -t f2fs -o ro "$OVERLAY_LOOP" "$MNT"
        tar -C "$MNT" -cpzf "$TARBALL" .
        umount "$MNT"
        [ -s "$TARBALL" ] || err "backup tar is empty; aborting"
        ok "  backup: $(ls -lh "$TARBALL")"
    fi

    losetup -d "$OVERLAY_LOOP" 2>/dev/null || true
    OVERLAY_LOOP=""

    AVAIL_BYTES=$(( TARGET_BYTES - OVERLAY_OFFSET ))
    log "  recreating f2fs with size $AVAIL_BYTES bytes"
    if [ "$DRY_RUN" -eq 0 ]; then
        NEW_LOOP=$(losetup --find --show --offset="$OVERLAY_OFFSET" --sizelimit="$AVAIL_BYTES" "$ROOTFS_PART")
        cleanup_add "losetup -d '$NEW_LOOP'"
        mkfs.f2fs -f "$NEW_LOOP"
        mount -t f2fs "$NEW_LOOP" "$MNT"
        tar -C "$MNT" -xpzf "$TARBALL"
        sync
        umount "$MNT"
        losetup -d "$NEW_LOOP"
        ok "  f2fs recreated and restored"
    fi
fi

# ---------------------------------------------------------------- Phase 4
log "shrinking partition $ROOTFS_NUM to $TARGET_SECTORS sectors"

PART_TYPE=$(sfdisk --dump "$DEV" 2>/dev/null \
    | awk -v p="$ROOTFS_PART" '$0 ~ "^"p" " {for(i=1;i<=NF;i++) if($i ~ /^type=/){sub(/^type=/,"",$i);sub(/,.*/,"",$i);print $i; exit}}')
PART_TYPE=${PART_TYPE:-83}
log "  partition type: $PART_TYPE"

if [ "$DRY_RUN" -eq 0 ]; then
    echo "$ROOTFS_START_SECTOR,$TARGET_SECTORS,$PART_TYPE" \
        | sfdisk --no-reread --force -N "$ROOTFS_NUM" "$DEV"
    sync
    partprobe "$DEV" 2>/dev/null || true
    sleep 1
fi

# ---------------------------------------------------------------- Phase 5
log "verifying"
MAGIC=$(dd if="$ROOTFS_PART" bs=1 count=4 2>/dev/null || true)
[ "$MAGIC" = "hsqs" ] || [ "$MAGIC" = "sqsh" ] || err "SquashFS magic missing after shrink! restore from backup"
ok "SquashFS superblock intact"

if [ "$DRY_RUN" -eq 0 ]; then
    log "  partition now $(human "$(blockdev --getsize64 "$ROOTFS_PART")") bytes"
fi

if [ "$OVERLAY_TYPE" != "none" ] && [ "$DRY_RUN" -eq 0 ]; then
    log "  mounting overlay read-only to verify data"
    VERIFY_LOOP=$(losetup --find --show --offset="$OVERLAY_OFFSET" "$ROOTFS_PART")
    cleanup_add "losetup -d '$VERIFY_LOOP'"
    VMOUNT=$(mktemp -d); cleanup_add "rmdir '$VMOUNT' 2>/dev/null || true"
    if mount -o ro "$VERIFY_LOOP" "$VMOUNT"; then
        df -h "$VMOUNT" >&2
        umount "$VMOUNT"
        ok "  overlay mounts cleanly"
    else
        err "overlay failed to mount! restore from backup"
    fi
    losetup -d "$VERIFY_LOOP" 2>/dev/null || true
fi

log "final partition table:"
sfdisk --dump "$DEV" >&2

ok "done. freed space is unallocated at the end of $DEV."
