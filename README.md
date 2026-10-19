# PS5 Linux Image Builder

Builds bootable Linux USB images for PlayStation 5 using Docker containers. Supports Ubuntu 26.04, Arch, CachyOS (Gamescope + Steam), Fedora (GNOME), individually or as a multi-distro image with kexec switching.

## Prerequisites

- Docker (with permission to run `--privileged` containers) — install as per your distro's instructions
- ~30GB free disk space for Ubuntu, Arch, or CachyOS

Once Docker is installed, add your user to the docker group and apply it without logging out:

```bash
sudo usermod -aG docker $USER
newgrp docker
```

## Quick Start

```bash
# Build a single Ubuntu 26.04 image
./build_image.sh --distro ubuntu2604

OR

# Build CachyOS (Arch-based, Gamescope + Steam Big Picture)
./build_image.sh --distro cachyos

OR

OR

# Build Fedora (GNOME desktop)
./build_image.sh --distro fedora

OR

# Build a multi-distro image (ubuntu2604 + arch + cachyos)
./build_image.sh --distro all
```

The script auto-clones Linux **7.2.11** (`v7.2.11`) to `work/linux/`, applies patches from the `main` branch of [`ps5-linux/ps5-linux-patches`](https://github.com/ps5-linux/ps5-linux-patches), compiles, and builds the image. The PS5 mwifiex driver also uses the `main` branch of [`ps5-linux/ps5-linux-mwifiex`](https://github.com/ps5-linux/ps5-linux-mwifiex). The kernel target is fixed independently of the patch set's `.config` version; `--patches-ref` changes only the patch revision.

Before applying the kernel patches, `patches/linux-7.2.11.patch` strictly rebases the upstream patch context to preserve Linux 7.2.11's Bluetooth flag and AMD I2C resource-cleanup fixes alongside all upstream PS5 changes. Alternate `--patches-ref` revisions must be compatible with this local context rebase and the Linux 7.2.11 target; incompatible revisions fail without a fallback.

During kernel compilation, `work/ps5-linux-patches/` is mounted read-only at `/ps5-linux-patches` alongside the kernel source at `/src`. This keeps the upstream PS5 AMD firmware available through the configured `../ps5-linux-patches/firmware` path without disabling embedded firmware.

Subsequent runs reuse cached artifacts automatically. Press Ctrl+C at any time to abort cleanly.

## Flash to USB

```bash
sudo dd if=output/ps5-ubuntu2604.img of=/dev/sdX bs=4M status=progress
```

## Options

| Flag | Description | Default |
|------|-------------|---------|
| `--distro` | `ubuntu2604`, `arch`, `cachyos`, `fedora`, or `all` | `ubuntu2604` |
| `--kernel` | Path to kernel source directory | auto-clone Linux `v7.2.11` to `work/linux/` |
| `--img-size` | Disk image size in MB | `12000` (`32000` for `all`) |
| `--clean` | Remove all cached build artifacts and start fresh | off |
| `--kernel-only` | Build and package the kernel only, then exit | off |
| `--patches-ref` | Branch, tag, or commit SHA for PS5 kernel patches | `main` |

Set the `PATCHES_REPO` environment variable to select a different patch repository; unset or empty values use `https://github.com/ps5-linux/ps5-linux-patches.git`. Fork CI sets this to its own patch repository URL and uses `--patches-ref` to select the exact fork revision.

## Caching

The build automatically skips stages that have already completed:

- **Kernel source** — reused if `work/linux/` exists
- **Kernel packages** — reused if `.deb`/`.pkg.tar.zst` files exist in `linux-bin/`
- **Root filesystem** — reused if chroot directories are populated

Use `--clean` to wipe everything and rebuild from scratch. Existing cached kernel sources and packages are not updated when defaults, `PATCHES_REPO`, or `--patches-ref` change; use `--clean` to switch them to Linux 7.2.11 and the `main` branches (or your chosen patch repository and ref). The build will also suggest `--clean` if a stage fails.

## Build Output

```
PS5 Linux Image Builder
=======================
  Distro:       all
                (ubuntu2604 arch cachyos)
  Image size:   32000MB
  Kernel src:   /path/to/work/linux

Stages:
  1. Kernel            cached
  2. Root filesystem   build
  3. Disk image        build

Logs: /path/to/build.log

  ✓ Kernel packages (cached)
  ✓ Build image builder image
  ⠹ Building arch rootfs
```

All verbose output goes to `build.log`. The terminal shows a spinner with live progress.

## Distributions

| Distro | Desktop | Kernel format | Init |
|--------|---------|---------------|------|
| Ubuntu 26.04 (Resolute) | GNOME | `.deb` | systemd |
| Arch | Sway | `.pkg.tar.zst` | systemd |
| CachyOS | Gamescope + Steam Big Picture (Arch + `[cachyos]` repo, no v3 migration in image build) | `.pkg.tar.zst` | systemd |

## Multi-distro Image

`--distro all` builds a 32GB image with 4 partitions (one EFI boot partition plus three root filesystems):

| Partition | Type | Label | Content |
|-----------|------|-------|---------|
| p1 | FAT32 | boot | Shared kernel, per-distro initrds, kexec scripts |
| p2 | ext4 | ubuntu2604 | Ubuntu 26.04 rootfs |
| p3 | ext4 | arch | Arch rootfs |
| p4 | ext4 | cachyos | CachyOS rootfs |

The boot partition contains kexec scripts to switch between distros at runtime. Ubuntu 26.04 is the default boot target.

## Building the Kernel Standalone

Use `--kernel-only` to compile the PS5 kernel and produce installable packages without building a full disk image.

```bash
./build_image.sh --kernel-only                                # .deb (default)
./build_image.sh --kernel-only --distro all                   # .deb + .pkg.tar.zst
./build_image.sh --kernel-only --patches-ref main             # explicitly select the patches branch
./build_image.sh --kernel-only --clean                        # wipe and rebuild from scratch
```

Output packages are written to `linux-bin/`. Install on a running PS5 Linux system:

```bash
sudo dpkg -i linux-bin/linux-ps5_*.deb
```

The Debian package's post-install script builds the initramfs for the packaged kernel release using the available initramfs tool and, if `/boot/efi` exists, copies that release's kernel and initramfs there as `bzImage` and `initrd.img`. It uses the packaged release, not whichever directory in `/lib/modules` is newest.

## Directory Layout

```
build_image.sh                  # Image builder (also supports --kernel-only)
docker/
  kernel-builder/               # Kernel compilation container
  kernel-builder-arch/          # Repackages .deb kernel as .pkg.tar.zst
  image-builder/
    Dockerfile                  # Image building container (distrobuilder)
    entrypoint.sh               # Single-distro build logic
    entrypoint-multi.sh         # Multi-distro build logic
distros/
  ubuntu2604/                   # Ubuntu 26.04 (Resolute)
  arch/                         # Arch Linux
  cachyos/                      # CachyOS repos + Gamescope/Steam
  shared/                       # Kernel postinst hooks (single + multi)
boot/
  cmdline.txt                   # Kernel cmdline template (__DISTRO__ placeholder)
  vram.txt                      # VRAM allocation
  kexec-{ubuntu2604,arch,cachyos}.sh
work/                           # Build artifacts (auto-created)
linux-bin/                      # Compiled kernel packages
output/                         # Final .img files
```
