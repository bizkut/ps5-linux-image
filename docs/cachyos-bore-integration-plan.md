# CachyOS BORE Kernel Integration Plan

## Goal

Add a PS5 CachyOS BORE kernel build path while keeping each upstream project
separately updateable:

- `linux-cachyos` stays the source for CachyOS package recipes and kernel
  profile defaults, fetched from `https://github.com/CachyOS/linux-cachyos`.
- `https://github.com/CachyOS/linux` stays the source for CachyOS kernel
  release tarballs.
- `cachyos-kernel-patches` stays the source for CachyOS patch stacks, including
  BORE, fetched from `https://github.com/CachyOS/kernel-patches`.
- `ps5-linux-patches` stays the source for PS5-specific enablement.
- `ps5-linux-image` orchestrates the combined build and image packaging.

The target is a CachyOS image using a PS5-enabled CachyOS BORE kernel. The
current CachyOS metadata points at Linux 7.0.12, while the existing PS5 patch
set was developed against Linux 7.0.10, so the PS5 patch overlay must be rebased
onto the CachyOS 7.0.12 patch stack.

## Repository Boundaries

Keep the upstream inputs clean and pull-friendly. `ps5-linux-image` should fetch
and cache them under its own `work/upstreams/` directory during builds:

```text
<WORKSPACE_ROOT>/upstreams/linux-cachyos
<WORKSPACE_ROOT>/upstreams/kernel-patches
<WORKSPACE_ROOT>/ps5-linux-patches
<WORKSPACE_ROOT>/ps5-linux-image
```

Local sibling checkouts of the CachyOS repos are useful for inspection, but the
production build path should use the upstream GitHub URLs so a clean
`ps5-linux-image` checkout is self-contained.

### linux-cachyos

Use this as read-only upstream input for CachyOS package recipes and config
choices. Do not add PS5 patches here. This repository is not the kernel source
tree; its PKGBUILD selects release tarballs from `https://github.com/CachyOS/linux`.

Relevant profile for BORE:

```text
linux-cachyos/linux-cachyos-bore/
  PKGBUILD
  config
  .SRCINFO
```

### cachyos-kernel-patches

Use this as read-only upstream input for CachyOS kernel patch stacks. Do not
copy these patches into `ps5-linux-patches`.

Relevant Linux 7.0 scheduler patches include:

```text
cachyos-kernel-patches/7.0/
  sched/0001-bore.patch
  sched/0001-bore-cachy.patch
  ...
```

Do not hardcode this list in `ps5-linux-image`. The selected CachyOS PKGBUILD
must remain the source of truth for which patches are applied. For example,
`linux-cachyos-bore/PKGBUILD` currently selects `sched/0001-bore-cachy.patch`
for the `bore` profile through its `source[]` construction.

### CachyOS linux

Use `https://github.com/CachyOS/linux` as the CachyOS kernel source upstream.
The selected source URL should follow the CachyOS PKGBUILD values:

```text
https://github.com/CachyOS/linux/releases/download/${_srcname}/${_srcname}.tar.gz
```

For the current BORE metadata, that resolves to a `cachyos-7.0.12-1` release
tarball. The kernel.org stable tree remains the source only for the existing
`ps5-stable` profile.

### ps5-linux-patches

Keep this repository limited to PS5 enablement and PS5 config deltas.

Recommended future structure:

```text
ps5-linux-patches/
  profiles/
    stable-7.0/
      base.config
      series
      patches/*.patch

    cachyos-7.0-bore/
      ps5.config
      series
      patches/*.patch
```

For the CachyOS BORE path, `ps5.config` should be a small overlay, not a full
CachyOS config copy. Example:

```text
CONFIG_X86_PS5=y
CONFIG_AMD_NB=y
# CONFIG_X86_ACPI_CPUFREQ is not set
```

### ps5-linux-image

This repository should coordinate source selection, patch application, config
merging, build, and package/image output.

## Build Model

Separate distro choice from kernel profile.

Current behavior:

```sh
./build_image.sh --distro cachyos
```

Proposed behavior:

```sh
./build_image.sh --distro cachyos --kernel-profile ps5-stable
./build_image.sh --distro cachyos --kernel-profile ps5-cachyos-bore
```

`--distro cachyos` controls root filesystem and package format.

`--kernel-profile ps5-cachyos-bore` controls:

- kernel source version
- CachyOS patch stack
- scheduler selection
- PS5 patch overlay
- config overlay
- package name/version

## Proposed ps5-linux-image Layout

Add explicit profile metadata and helper scripts:

```text
kernel-profiles/
  ps5-stable.env
  ps5-cachyos-bore.env

scripts/
  kernel-profile-lib.sh
  prepare-cachyos-kernel.sh
  apply-ps5-overlay.sh
  merge-kernel-config.sh
```

Example `kernel-profiles/ps5-cachyos-bore.env`:

```sh
KERNEL_BASE=cachyos
KERNEL_SOURCE_REPO=https://github.com/CachyOS/linux
KERNEL_PACKAGE_NAME=linux-ps5-cachyos-bore
KERNEL_LOCALVERSION=-ps5-cachyos-bore

CACHYOS_PKG_REPO=https://github.com/CachyOS/linux-cachyos.git
CACHYOS_PKG_REF=master
CACHYOS_PKG_PROFILE=linux-cachyos-bore
CACHYOS_PATCH_REPO=https://github.com/CachyOS/kernel-patches.git
CACHYOS_PATCH_REF=master
CACHYOS_EXPECTED_MAJOR=7.0

CACHYOS_SCHED=bore
CACHYOS_CONFIG=1
PS5_CONFIG_FRAGMENT=profiles/cachyos-7.0-bore/ps5.config
PS5_PATCH_SERIES=profiles/cachyos-7.0-bore/series
```

The profile file should be small and declarative. Script logic should live in
`scripts/`, not inside the profile.

`CACHYOS_PKG_REF` must match the intended kernel line. As of June 11, 2026,
`linux-cachyos` does not expose a `7.0` branch, while `master` contains
`_major=7.0` and `_minor=12` for the BORE profile. Keep
`CACHYOS_EXPECTED_MAJOR=7.0` so the build fails if `master` moves to a new
kernel line before the PS5 overlay has been rebased.

## CachyOS Patch Selection

Use the selected CachyOS PKGBUILD to derive the patch list instead of copying
or re-declaring CachyOS patch names.

For the first implementation, support a constrained parser for the patch source
patterns already used by `linux-cachyos-bore/PKGBUILD`:

- base source tarball
- `config`
- `_patchsource/sched/...`
- optional `_patchsource/misc/...` entries selected by profile variables

The parser should produce a build-local manifest:

```text
work/kernel-profiles/ps5-cachyos-bore/cachyos-patches.series
```

Each line should contain the resolved local patch path under
`cachyos-kernel-patches/7.0`.

This keeps CachyOS updates easy: pull `linux-cachyos` and
`cachyos-kernel-patches`, then regenerate the manifest.

## Patch Application Order

For `ps5-cachyos-bore`, the kernel tree should be prepared in this order:

1. Read `pkgver`, `pkgrel`, `_srcname`, and `_major` from the selected
   CachyOS PKGBUILD.
2. Fetch or use the CachyOS-selected Linux source tarball from
   `https://github.com/CachyOS/linux`, currently `cachyos-7.0.12-1`.
3. Copy the selected CachyOS `config` to `.config`.
4. Apply the CachyOS patch manifest derived from the PKGBUILD source list.
5. Apply PS5 patches from `ps5-linux-patches`.
6. Apply profile config changes with `scripts/config`, matching the CachyOS
   PKGBUILD behavior for BORE, Cachy config, tick rate, preemption, CPU
   optimization, and optional features.
7. Apply PS5 config fragment on top.
8. Run `make olddefconfig`.

This keeps upstream CachyOS changes separate from PS5 changes and makes future
updates a rebase of only the PS5 overlay.

## Package Naming

Do not overwrite the plain `linux-ps5` package.

Use a distinct package and module namespace:

```text
Package: linux-ps5-cachyos-bore
Kernel release: 7.0.12-ps5-cachyos-bore
Modules: /usr/lib/modules/7.0.12-ps5-cachyos-bore
```

This makes rollback and side-by-side testing practical.

Implementation detail: this needs `LOCALVERSION` or localversion files in the
prepared kernel source before compilation. The Arch packager should derive the
package name from the active kernel profile instead of always emitting
`linux-ps5`.

## ps5-linux-image Build Flow

For `--kernel-profile ps5-cachyos-bore`, `build_image.sh` should:

1. Resolve profile metadata.
2. Ensure kernel source and output directories are on a case-sensitive volume.
3. Download or reuse the selected CachyOS Linux release tarball for CachyOS
   profiles, or update kernel.org stable only for `ps5-stable`.
4. Generate a CachyOS patch manifest from the selected PKGBUILD.
5. Apply CachyOS patches.
6. Apply PS5 overlay patches.
7. Merge CachyOS and PS5 config.
8. Build with the existing Docker kernel builder.
9. Package with the existing Arch/CachyOS packager.
10. Install the resulting `.pkg.tar.zst` into the CachyOS rootfs.

## Validation Gates

Before running a full image build, validate patch and config compatibility:

```sh
git apply --check <cachyos patches>
git apply --check <ps5 patches>
make olddefconfig
grep CONFIG_SCHED_BORE .config
grep CONFIG_CACHY .config
grep CONFIG_X86_PS5 .config
make drivers/ps5/
make kernel/sched/
```

Then validate the full script path:

```sh
./build_image.sh --kernel-only --distro cachyos --kernel-profile ps5-cachyos-bore
./build_image.sh --distro cachyos --kernel-profile ps5-cachyos-bore
```

## Known Risks

- The existing PS5 patch set was developed against Linux 7.0.10 and must be
  rebased onto the CachyOS 7.0.12 patched tree.
- Current source-prep validation reaches the PS5 overlay and fails on the flat
  compatibility `linux.patch` in:
  - `drivers/gpu/drm/amd/amdgpu/amdgpu_drv.c`
  - `drivers/gpu/drm/amd/display/amdgpu_dm/amdgpu_dm.c`
- Likely conflict areas:
  - `arch/x86`
  - `drivers/gpu/drm/amd`
  - `drivers/hwmon/k10temp.c`
  - cpufreq ownership
  - kernel config
- BORE mostly changes scheduler code, so it should not heavily conflict with
  PS5 platform support.
- CachyOS config may re-enable generic CPU frequency drivers. The PS5 overlay
  must keep PS5 cpufreq ownership explicit.
- Linux source and output staging must be on a case-sensitive filesystem because
  Linux headers include files whose names differ only by case.

## First Implementation Milestone

1. Add `--kernel-profile`.
2. Add `ps5-cachyos-bore.env`.
3. Add profile loading and summary output to `build_image.sh`, without changing
   the default `ps5-stable` path.
4. Add a dry-run command that resolves the selected CachyOS version and patch
   manifest.
5. Implement local-source preparation using the existing local upstream
   checkouts.
6. Rebase PS5 patches onto CachyOS 7.0.12.
7. Build only `drivers/ps5/` and `kernel/sched/`.
8. Build `--kernel-only --distro cachyos --kernel-profile ps5-cachyos-bore`.
9. Boot-test on PS5.

## Non-Goals For First Milestone

- Do not fork or edit `linux-cachyos`.
- Do not fork or edit `cachyos-kernel-patches`.
- Do not import CachyOS patches into `ps5-linux-patches`.
- Do not enable LTO, KCFI, AutoFDO, Propeller, ZFS, NVIDIA, or out-of-tree
  modules until the BORE + PS5 base boots.
