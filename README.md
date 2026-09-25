# archlinux-lima

Arch Linux ARM image for [Lima](https://lima-vm.io) on Apple Silicon.

GitHub Actions builds the image every Monday from the official Arch Linux
ARM rootfs and publishes it as a release.

## What's included

- Arch Linux ARM aarch64 root filesystem, updated at build time
- EFI boot through systemd-boot, networking through systemd-networkd
- cloud-init, which applies Lima's user, SSH keys, and mounts on first boot
- `growpart`, so the root partition fills the disk size Lima sets

The image has no user and a locked root account.

## Use

Point a Lima template at the latest release:

```yaml
vmType: vz
images:
  - location: https://github.com/xkef/archlinux-lima/releases/latest/download/archlinux-aarch64.qcow2
    arch: aarch64
```

Lima caches the download by URL. Run `limactl prune` to fetch a newer
release.

## Build

`build.sh` runs as root on an arm64 Linux host:

```bash
sudo ./build.sh
```

It writes `.build/archlinux-aarch64.qcow2`. It needs `sgdisk`,
`mkfs.vfat`, `mkfs.ext4`, `bsdtar`, and `qemu-img`.
