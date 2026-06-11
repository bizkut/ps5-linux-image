#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
profile_file="${1:-}"
target_dir="${2:-}"
ps5_patchdir="${3:-}"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$SCRIPT_DIR/work}"

die() {
    echo "prepare-cachyos-kernel: $*" >&2
    exit 1
}

[ -n "$profile_file" ] || die "missing profile file"
[ -n "$target_dir" ] || die "missing target directory"
[ -f "$profile_file" ] || die "profile file not found: $profile_file"

# shellcheck disable=SC1090
. "$profile_file"

CACHYOS_WORKDIR="${CACHYOS_WORKDIR:-$WORKSPACE_ROOT/upstreams}"
CACHYOS_PKG_PROFILE="${CACHYOS_PKG_PROFILE:-linux-cachyos-bore}"
CACHYOS_PKGDIR="${CACHYOS_PKGDIR:-$CACHYOS_WORKDIR/linux-cachyos/$CACHYOS_PKG_PROFILE}"
CACHYOS_PATCHDIR="${CACHYOS_PATCHDIR:-$CACHYOS_WORKDIR/kernel-patches}"
export CACHYOS_WORKDIR

profile_lib="$SCRIPT_DIR/scripts/kernel-profile-lib.sh"
cache_dir="$WORKSPACE_ROOT/cache/cachyos"
extract_dir="$target_dir.extract"
ps5_patchdir="${ps5_patchdir:-${PS5_PATCHDIR:-}}"

[ -n "$ps5_patchdir" ] || die "missing PS5 patch directory"
[ -d "$ps5_patchdir" ] || die "PS5 patch directory not found: $ps5_patchdir"

mkdir -p "$cache_dir" "$(dirname "$target_dir")"

"$profile_lib" cachyos-sync "$profile_file"

srcname="$("$profile_lib" cachyos-srcname "$profile_file")"
source_url="$("$profile_lib" cachyos-source-url "$profile_file")"
tarball="$cache_dir/${srcname}.tar.gz"

if [ ! -f "$tarball" ]; then
    curl -fL --retry 3 --retry-delay 2 -o "$tarball" "$source_url"
fi

rm -rf "$extract_dir" "$target_dir"
mkdir -p "$extract_dir"
tar -xzf "$tarball" -C "$extract_dir"

if [ -d "$extract_dir/$srcname" ]; then
    mv "$extract_dir/$srcname" "$target_dir"
else
    first_dir="$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d | head -1)"
    [ -n "$first_dir" ] || die "source tarball did not contain a directory"
    mv "$first_dir" "$target_dir"
fi
rm -rf "$extract_dir"

git -C "$target_dir" init
git -C "$target_dir" add -A
git -C "$target_dir" commit -q -m "Import $srcname" || true

while IFS= read -r patch_file; do
    [ -n "$patch_file" ] || continue
    echo "Applying CachyOS patch $patch_file"
    git -C "$target_dir" apply "$patch_file"
done < <("$profile_lib" cachyos-patches "$profile_file")

cp "$CACHYOS_PKGDIR/config" "$target_dir/.config"
printf -- "-%s\n" "$("$profile_lib" cachyos-pkgrel "$profile_file")" > "$target_dir/localversion.10-pkgrel"
printf "%s\n" "$KERNEL_LOCALVERSION" > "$target_dir/localversion.20-ps5"

if [ -n "${PS5_PATCH_SERIES:-}" ] && [ -f "$ps5_patchdir/$PS5_PATCH_SERIES" ]; then
    ps5_series_file="$ps5_patchdir/$PS5_PATCH_SERIES"
    ps5_series_dir="$(dirname "$ps5_series_file")"

    while IFS= read -r patch_entry; do
        patch_entry="${patch_entry%%#*}"
        patch_entry="${patch_entry#"${patch_entry%%[![:space:]]*}"}"
        patch_entry="${patch_entry%"${patch_entry##*[![:space:]]}"}"
        [ -n "$patch_entry" ] || continue
        echo "Applying PS5 patch $patch_entry"
        git -C "$target_dir" apply "$ps5_series_dir/$patch_entry"
    done < "$ps5_series_file"
elif [ -f "$ps5_patchdir/linux.patch" ]; then
    echo "Applying PS5 compatibility patch linux.patch"
    if ! git -C "$target_dir" apply --exclude=Makefile "$ps5_patchdir/linux.patch"; then
        die "PS5 compatibility patch does not apply to $srcname; rebase PS5 patches into ${PS5_PATCH_SERIES:-a CachyOS profile series}"
    fi
else
    die "no PS5 patch series or linux.patch found in $ps5_patchdir"
fi

if [ -n "${PS5_CONFIG_FRAGMENT:-}" ] && [ -f "$ps5_patchdir/$PS5_CONFIG_FRAGMENT" ]; then
    "$target_dir/scripts/kconfig/merge_config.sh" -m "$target_dir/.config" "$ps5_patchdir/$PS5_CONFIG_FRAGMENT"
elif [ -f "$ps5_patchdir/.config" ]; then
    echo "Using PS5 compatibility config overlay from .config"
    cp "$ps5_patchdir/.config" "$target_dir/.config"
fi

git -C "$target_dir" add -A
git -C "$target_dir" commit -q -m "Apply CachyOS and PS5 profile patches" || true
