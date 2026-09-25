#!/usr/bin/env bash
set -euo pipefail

# Builds an Arch Linux ARM qcow2 image for Lima with vmType vz.
#
# Runs as root on an arm64 Linux host. The image holds the official rootfs,
# systemd-boot, and cloud-init. Lima's cloud-init data creates the user,
# the SSH keys, and the mounts at first boot, and cloud-init grows the root
# partition to the disk size Lima picks. fish ships in the image so a Lima
# template can make it the user's shell from the first boot.

DISK_SIZE="${DISK_SIZE:-4}"
TARBALL="${TARBALL:-http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz}"
BUILD_DIR="${BUILD_DIR:-$PWD/.build}"
IMAGE="${IMAGE:-$BUILD_DIR/archlinux-aarch64.qcow2}"
MNT="$BUILD_DIR/mnt"
RAW="$BUILD_DIR/disk.raw"

cleanup() {
  umount -R "$MNT" 2>/dev/null || true
  if [[ -n "${LOOP:-}" ]]; then
    losetup -d "$LOOP" 2>/dev/null || true
  fi
}
trap cleanup EXIT

mkdir -p "$BUILD_DIR" "$MNT"
rm -f "$RAW" "$IMAGE"

# One EFI system partition and one root partition, last on the disk so
# growpart can extend it.
truncate -s "${DISK_SIZE}G" "$RAW"
sgdisk -Z "$RAW" >/dev/null 2>&1
sgdisk -n 1:0:+512M -t 1:ef00 -n 2:0:0 -t 2:8300 "$RAW" >/dev/null

LOOP="$(losetup --find --show --partscan "$RAW")"
mkfs.vfat -F32 "${LOOP}p1" >/dev/null
mkfs.ext4 -qL root "${LOOP}p2" >/dev/null

mount "${LOOP}p2" "$MNT"
mkdir -p "$MNT/boot"
mount "${LOOP}p1" "$MNT/boot"

if [[ ! -f "$BUILD_DIR/alarm.tar.gz" ]]; then
  curl -fSL "$TARBALL" -o "$BUILD_DIR/alarm.tar.gz"
fi
bsdtar -xpf "$BUILD_DIR/alarm.tar.gz" -C "$MNT"

mkdir -p "$MNT/boot/loader/entries"
printf 'default arch.conf\ntimeout 0\n' >"$MNT/boot/loader/loader.conf"
printf 'title Arch Linux ARM\nlinux /Image\ninitrd /initramfs-linux.img\noptions root=LABEL=root rw console=hvc0\n' \
  >"$MNT/boot/loader/entries/arch.conf"
printf 'LABEL=root / ext4 defaults 0 1\n' >"$MNT/etc/fstab"

# DHCP on every wired interface, in case cloud-init writes no network config.
mkdir -p "$MNT/etc/systemd/network"
printf '[Match]\nName=en* eth*\n\n[Network]\nDHCP=yes\n' \
  >"$MNT/etc/systemd/network/20-wired.network"

# Apple Virtualization freezes the guest clock during host sleep and sends
# no resume event. A short poll interval re-syncs the clock within 30s.
mkdir -p "$MNT/etc/systemd/timesyncd.conf.d"
printf '[Time]\nPollIntervalMinSec=16\nPollIntervalMaxSec=32\n' \
  >"$MNT/etc/systemd/timesyncd.conf.d/10-vm-poll.conf"

# LLMNR and multicast DNS have no use in a VM, and Lima would forward their
# ports to the host.
mkdir -p "$MNT/etc/systemd/resolved.conf.d"
printf '[Resolve]\nLLMNR=no\nMulticastDNS=no\n' \
  >"$MNT/etc/systemd/resolved.conf.d/10-vm.conf"

mount --bind /dev "$MNT/dev"
mount --bind /proc "$MNT/proc"
mount --bind /sys "$MNT/sys"

rm -f "$MNT/etc/resolv.conf"
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' >"$MNT/etc/resolv.conf"
touch "$MNT/etc/vconsole.conf"

chroot "$MNT" /bin/bash <<'CHROOT'
set -euo pipefail
pacman-key --init
pacman-key --populate archlinuxarm
pacman -Syu --noconfirm
pacman -S --needed --noconfirm \
  openssh sudo mkinitcpio cloud-init cloud-guest-utils fish

bootctl install --esp-path=/boot --no-variables
sed -i 's/^MODULES=.*/MODULES=(virtio_pci virtio_net virtio_blk virtio_mmio virtio_ring)/' \
  /etc/mkinitcpio.conf
mkinitcpio -P

sed -i 's/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
echo 'LANG=en_US.UTF-8' >/etc/locale.conf

systemctl enable sshd systemd-networkd systemd-resolved systemd-timesyncd
systemctl enable $(cd /usr/lib/systemd/system && ls cloud-*.service)

# Lima brings its own user. Drop the stock alarm user and lock root, whose
# stock password is "root".
userdel -r alarm
passwd -l root

# Every VM gets its own machine ID and SSH host keys on first boot.
: >/etc/machine-id
rm -f /etc/ssh/ssh_host_*
rm -rf /var/cache/pacman/pkg/*

# pacman-key leaves a gpg-agent running, which keeps the mount busy.
gpgconf --homedir /etc/pacman.d/gnupg --kill all
CHROOT

ln -sf /run/systemd/resolve/stub-resolv.conf "$MNT/etc/resolv.conf"

umount -R "$MNT"
losetup -d "$LOOP"
unset LOOP

qemu-img convert -c -O qcow2 "$RAW" "$IMAGE"
rm -f "$RAW"
printf 'Built %s\n' "$IMAGE"
