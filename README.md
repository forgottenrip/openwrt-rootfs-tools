# openwrt-rootfs-tools

Safely shrink the OpenWrt rootfs partition on an SD card from a Linux PC,
and mount the hidden writable overlay for inspection or modification.

## The problem

OpenWrt on Raspberry Pi (and many SBCs) stores its root filesystem as a
read-only **SquashFS** image followed by a writable **ext4** or **f2fs**
overlay inside the same partition. The usual "expand rootfs" scripts grow
that partition to fill the SD card — and then no GUI tool can undo it.
GParted sees 'squashfs'; GNOME Disks sees 'squashfs'; 'fdisk' alone
leaves the overlay superblock pointing past the new partition boundary,
bricking the boot.

The overlay is hidden at a non-standard offset inside the partition, invisible to blkid, wipefs, and every GUI partition manager.

This repository contains two scripts that handle it correctly:

| scripts/openwrt-rootfs-shrink.sh | Shrink the rootfs partition back to any target size.
| scripts/openwrt-overlay-mount.sh | Mount the ext4/f2fs overlay for read-write access.

## Usage
```bash
sudo ./scripts/openwrt-rootfs-shrink.sh -n --size 4G /dev/sdb
sudo ./scripts/openwrt-rootfs-shrink.sh --size 4G -b /root/sd.img /dev/sdb
sudo ./scripts/openwrt-overlay-mount.sh /dev/sdb
sudo ./scripts/openwrt-overlay-mount.sh --unmount
```


What It Does

openwrt-rootfs-shrink.sh shrinks the rootfs partition of an OpenWrt SD card back to any target size you choose, handling all three possible layouts automatically:

    SquashFS + ext4 overlay	Shrink the ext4 filesystem in-place with resize2fs, then shrink the partition

    SquashFS + f2fs overlay	Back up the overlay, recreate it at the smaller size, restore, then shrink the partition (requires --allow-f2fs-rebuild)

    SquashFS only (no overlay)	Shrink the partition entry only; no filesystem work

Why Not Just Use GParted?
Because the overlay lives at an offset that GParted never looks at. Shrinking the partition table entry without first shrinking the overlay's filesystem produces a device that:
    
    • has a partition smaller than the filesystem inside it,
    
    • makes the kernel refuse to mount the overlay (or mount it read-only after I/O errors),
    
    • and bricks the boot because OpenWrt's mount_root cannot attach the writable layer.

The correct order is always filesystem first, partition second — and only a tool that knows where the overlay is can do the first step. That is what this script is for.

Features
    
    • Automatic layout detection — reads the SquashFS superblock for its true size, then scans a bounded 32 MB window after it for ext4 / f2fs magic. Each candidate is verified with blkid on a loop device, so false positives from unrelated data are impossible.
    
    • Filesystem-first, partition-second — the only safe order. The partition table is never touched until the overlay has been resized or rebuilt.
    
    • Pre-flight safety checks — refuses to run on a partition (not a whole disk), refuses if any partition is mounted, refuses if a stale loop device is attached, refuses if the target size is smaller than the SquashFS image or the overlay offset.
    
    • Minimum-size validation — queries the actual minimum shrink size with resize2fs -P and aborts if your target is below it, rather than letting resize2fs half-complete and fail.
    
    • Verification after the fact — re-reads the SquashFS magic, re-attaches the overlay via loop, mounts it read-only, and prints df -h so you can see the new size and confirm your data is intact.
    
    • Dry-run mode — -n prints every destructive command (dd, resize2fs, mkfs.f2fs, sfdisk) without executing a single one.
    
    • Full-disk backup option — -b FILE writes a byte-for-byte image of the SD card before any change.
    
    • Clean teardown — every loop device and temporary file created is torn down on exit, including on error.

Requirements
    
    • Linux PC with the SD card in a reader (macOS and Windows are not supported).
    
    • Root privileges.
    
    • Tools: e2fsprogs, util-linux (for sfdisk, losetup, blkid, findmnt), f2fs-tools (only if shrinking an f2fs overlay).
    
    • The SD card's partitions must be unmounted before running.
    
Install the dependencies on Debian/Ubuntu:
```bash
sudo apt install e2fsprogs util-linux f2fs-tools
```
On Arch/Manjaro:
```bash
sudo pacman -S e2fsprogs util-linux f2fs-tools
```

Usage
```bash
chmod +x openwrt-rootfs-shrink.sh
```

# Always start with a dry run
sudo ./openwrt-rootfs-shrink.sh -n --size 4G /dev/sdb

# Real run, with a full backup written first
```bash
sudo ./openwrt-rootfs-shrink.sh --size 4G --backup-image /root/openwrt-sd.img /dev/sdb
```
Options

-s, --size SIZE	Target partition size. Default 4G. Accepts K, M, G suffixes.

-b, --backup-image FILE	Write a full-disk image to FILE before making changes. Strongly recommended.

-y, --yes	Skip interactive confirmation prompts.

-n, --dry-run	Print what would happen without executing any destructive command.

--allow-f2fs-rebuild	Required if the overlay is f2fs, since f2fs cannot be shrunk in place.

-h, --help	Show usage.


Examples
Shrink to 8 GB with a backup:
```bash
sudo ./openwrt-rootfs-shrink.sh --size 8G -b /backup/openwrt.img /dev/sdb
```
Preview the plan without touching anything:
```bash
sudo ./openwrt-rootfs-shrink.sh -n --size 4G /dev/sdb
```
f2fs overlay (backup → rebuild → restore path):
```bash
sudo ./openwrt-rootfs-shrink.sh --size 4G --allow-f2fs-rebuild /dev/sdb
```
How It Works
The script proceeds in six phases, and stops immediately if any phase fails or produces an unexpected result.
1. Pre-flight — Confirms the target is a whole disk (not a partition), that nothing on it is mounted, and that no stale loop devices are attached. Prints the current partition table.
2. Backup — If --backup-image is given, writes the entire SD card to an image file with dd conv=fsync. If not, warns you and requires explicit confirmation to continue without one.
3. Layout detection — Reads the SquashFS bytes_used field from offset 40 of the rootfs partition. Scans the next 32 MB for 53 ef (ext4-family) and 10 20 f5 f2 (f2fs) magic bytes, attaching a loop device at each candidate and confirming the type with blkid. The result is a concrete (filesystem type, offset in bytes) pair.
4. Target computation — Converts your --size to sectors, then checks:
    
    • target is smaller than the current partition,
    
    • target is larger than the SquashFS image,
    
    • target is larger than the overlay offset,
    
    • the space remaining after the overlay offset is large enough for the overlay's actual data (verified with resize2fs -P for ext4).
5. Filesystem shrink —
    
    • ext4: e2fsck -f, then resize2fs to (target_bytes - overlay_offset) / block_size × 0.99, then re-reads the block count to confirm.
    
    • f2fs: backs up the overlay to a temporary tarball, recreates it at the new size with mkfs.f2fs -f on a size-limited loop device, restores the tarball, and verifies.
    
    • No overlay: nothing to shrink.
6. Partition shrink — Uses sfdisk --no-reread --force -N <num> to rewrite only the target partition entry, preserving the original start sector and partition type exactly. fdisk and parted are deliberately avoided because they can alter boot attributes in ways that leave OpenWrt unbootable.
7. Verification — Re-reads the SquashFS magic, re-attaches the overlay via a loop device, mounts it read-only, prints df -h, and unmounts. Any failure here is a hard error, since it means data integrity is in question.
Throughout, the script tracks every loop device and temp file it creates in a cleanup array, so an error at any point leaves the system in the state it started in.

Safety Model
This script assumes you might be having a bad day. It is designed so that the most likely failure mode is "nothing happened" rather than "something got corrupted."
    
    • Refuses to run on mounted partitions, stale loop devices, partitions instead of disks, or targets smaller than the SquashFS.
    
    • Refuses to shrink ext4 below resize2fs -P's reported minimum.
    
    • Refuses to proceed past layout detection if no overlay is found when the target requires one to exist.
    
    • Refuses to write the partition table until the overlay resize has succeeded and been verified.
    
    • Refuses to claim success unless the SquashFS magic and the overlay mount both pass verification at the end.
    
    • Never creates partitions — the freed space is left for you to allocate as you see fit.

Post-Run
After a successful run:
    
    • The rootfs partition has shrunk to your target.
    
    • The freed space is unallocated at the end of the disk.
    
    • Your OpenWrt overlay data is intact and mountable.
    
    • The SquashFS magic is verified intact.
To create new partitions in the freed space, use fdisk or sfdisk yourself. Do not run wipefs -a on the rootfs partition — that erases the SquashFS magic and renders the card unbootable.
To access the overlay data from a Linux PC after shrinking, use the companion script openwrt-overlay-mount.sh — it detects the overlay at the correct offset, mounts it read-write at a mountpoint of your choice, and cleanly unmounts when you're done.

Recovery
If something goes wrong and the card will not boot:
    1. If you ran with --backup-image, restore with:
       ```bash
       sudo dd if=/root/openwrt-sd.img of=/dev/sdb bs=4M status=progress
       ```
    2. If you did not, and the SquashFS magic was lost, restore it manually:
       ```bash
       echo -n 'hsqs' | sudo dd of=/dev/sdb2 bs=1 seek=0 conv=notrunc
       ```
       Then verify with:
       ```bash
       sudo unsquashfs -s /dev/sdb2
       ```
    3. If the overlay filesystem is dirty from an unclean shutdown (common after a failed shrink), the kernel will refuse to mount it. Run a filesystem check on it:
       ```bash
       sudo losetup -o <offset> --find --show /dev/sdb2
       sudo e2fsck -f /dev/loopX
       ```
If none of that helps, the OpenWrt overlay is almost always disposable — the SquashFS is the actual boot image, and OpenWrt can be re-flashed with its original factory image and then re-expanded with the usual script. That is why the script's job is to preserve the SquashFS above everything else.

Caveats
    
    • Raspberry Pi (and similar SBC) only — the offset-based SquashFS + overlay layout is specific to OpenWrt images built for boards where the bootloader cannot boot from SquashFS directly.
    
    • MBR partition tables — the script uses sfdisk and reads sector sizes correctly for both MBR and GPT, but has only been tested on MBR (the default for Raspberry Pi SD images).
    
    • No progress bar during e2fsck or resize2fs — those tools take minutes to hours depending on the size of the overlay and the speed of the SD reader. The script logs start and end times, but the long wait in the middle is unavoidable.
    
    • f2fs overlay handling requires a full backup/restore cycle — there is no in-place f2fs shrink, by design of f2fs itself. This means twice the write I/O and twice the time on an f2fs card.

License
MIT. Use at your own risk; the script is conservative, but no script can prevent data loss from a failing SD card, a power cut during a resize2fs, or a mistake in --size. Back up first.

Contributing
Issues and pull requests welcome. If you hit a layout the script fails to detect, please include:
    
    • sudo sfdisk --dump /dev/sdX
    
    • sudo unsquashfs -s /dev/sdX2
    
    • The offset of the overlay if you can find it (e.g., sudo losetup -o <offset> --find --show /dev/sdX2; sudo blkid)
That is enough to reproduce the detection failure without needing to touch a real card.






