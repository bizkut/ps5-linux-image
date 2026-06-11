#!/usr/bin/env bash
set -euo pipefail

cmd="${1:-}"
profile_file="${2:-}"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "$(dirname "$0")/.." && pwd)/work}"

die() {
    echo "kernel-profile-lib: $*" >&2
    exit 1
}

[ -n "$cmd" ] || die "missing command"
[ -n "$profile_file" ] || die "missing profile file"
[ -f "$profile_file" ] || die "profile file not found: $profile_file"

# shellcheck disable=SC1090
. "$profile_file"

CACHYOS_WORKDIR="${CACHYOS_WORKDIR:-$WORKSPACE_ROOT/upstreams}"
CACHYOS_PKG_REPO="${CACHYOS_PKG_REPO:-https://github.com/CachyOS/linux-cachyos.git}"
CACHYOS_PKG_REF="${CACHYOS_PKG_REF:-master}"
CACHYOS_PKG_PROFILE="${CACHYOS_PKG_PROFILE:-linux-cachyos-bore}"
CACHYOS_PATCH_REPO="${CACHYOS_PATCH_REPO:-https://github.com/CachyOS/kernel-patches.git}"
CACHYOS_PATCH_REF="${CACHYOS_PATCH_REF:-master}"
CACHYOS_PKGDIR="${CACHYOS_PKGDIR:-$CACHYOS_WORKDIR/linux-cachyos/$CACHYOS_PKG_PROFILE}"
CACHYOS_PATCHDIR="${CACHYOS_PATCHDIR:-$CACHYOS_WORKDIR/kernel-patches}"

pkgbuild="${CACHYOS_PKGDIR:-}/PKGBUILD"

sync_git_repo() {
    local repo="$1" ref="$2" dir="$3"

    mkdir -p "$(dirname "$dir")"
    if [ ! -d "$dir/.git" ]; then
        git clone --depth 1 --branch "$ref" "$repo" "$dir"
    else
        git -C "$dir" fetch --depth 1 origin "$ref" || git -C "$dir" fetch origin "$ref"
        git -C "$dir" reset --hard FETCH_HEAD
    fi
}

sync_cachyos_inputs() {
    sync_git_repo "$CACHYOS_PKG_REPO" "$CACHYOS_PKG_REF" "$CACHYOS_WORKDIR/linux-cachyos"
    sync_git_repo "$CACHYOS_PATCH_REPO" "$CACHYOS_PATCH_REF" "$CACHYOS_PATCHDIR"
    validate_cachyos_inputs
}

require_pkgbuild() {
    [ -f "$pkgbuild" ] || die "CachyOS PKGBUILD not found: $pkgbuild"
}

validate_cachyos_inputs() {
    local expected_major actual_major srcname source_tag

    require_pkgbuild

    expected_major="${CACHYOS_EXPECTED_MAJOR:-}"
    actual_major="$(cachyos_major)"
    if [ -n "$expected_major" ] && [ "$actual_major" != "$expected_major" ]; then
        die "CachyOS PKGBUILD major mismatch: expected $expected_major from $CACHYOS_PKG_REF, got $actual_major"
    fi

    srcname="$(cachyos_srcname)"
    source_tag="$(git ls-remote --tags "${KERNEL_SOURCE_REPO:-https://github.com/CachyOS/linux}" "$srcname")"
    [ -n "$source_tag" ] || die "CachyOS Linux source tag not found: $srcname"
}

pkgbuild_value() {
    local name="$1"

    require_pkgbuild

    awk -F= -v key="$name" '
        $1 == key {
            val = $0
            sub(/^[^=]+=/, "", val)
            gsub(/^["'\''"]|["'\''"]$/, "", val)
            print val
            exit
        }
    ' "$pkgbuild"
}

cachyos_major() {
    local major

    major="$(pkgbuild_value _major)"
    [ -n "$major" ] || die "could not read _major from $pkgbuild"
    echo "$major"
}

cachyos_pkgver() {
    local major minor pkgver

    pkgver="$(pkgbuild_value pkgver)"
    if [ -n "$pkgver" ] && [[ "$pkgver" != *'${'* ]]; then
        echo "$pkgver"
        return
    fi

    major="$(pkgbuild_value _major)"
    minor="$(pkgbuild_value _minor)"
    [ -n "$major" ] || die "could not read _major from $pkgbuild"
    [ -n "$minor" ] || die "could not read _minor from $pkgbuild"
    echo "${major}.${minor}"
}

cachyos_pkgrel() {
    local pkgrel

    pkgrel="$(pkgbuild_value pkgrel)"
    [ -n "$pkgrel" ] || die "could not read pkgrel from $pkgbuild"
    echo "$pkgrel"
}

cachyos_srcname() {
    echo "cachyos-$(cachyos_pkgver)-$(cachyos_pkgrel)"
}

cachyos_source_url() {
    local source_repo srcname

    source_repo="${KERNEL_SOURCE_REPO:-https://github.com/CachyOS/linux}"
    srcname="$(cachyos_srcname)"
    echo "${source_repo}/releases/download/${srcname}/${srcname}.tar.gz"
}

emit_cachyos_patch_manifest() {
    local major patchdir sched

    major="$(cachyos_major)"
    sched="${CACHYOS_SCHED:-bore}"
    patchdir="${CACHYOS_PATCHDIR:?missing CACHYOS_PATCHDIR}/${major}"

    [ -d "$patchdir" ] || die "CachyOS patch directory not found: $patchdir"

    case "$sched" in
        cachyos|bore|rt-bore|hardened)
            [ -f "$patchdir/sched/0001-bore-cachy.patch" ] || die "missing BORE CachyOS patch"
            echo "$patchdir/sched/0001-bore-cachy.patch"
            ;;
        bmq)
            [ -f "$patchdir/sched/0001-prjc-cachy.patch" ] || die "missing Project C CachyOS patch"
            echo "$patchdir/sched/0001-prjc-cachy.patch"
            ;;
        eevdf)
            ;;
        rt)
            [ -f "$patchdir/misc/0001-rt-i915.patch" ] || die "missing RT patch"
            echo "$patchdir/misc/0001-rt-i915.patch"
            ;;
        *)
            die "unsupported CachyOS scheduler: $sched"
            ;;
    esac

    case "$sched" in
        hardened)
            [ -f "$patchdir/misc/0001-hardened.patch" ] || die "missing hardened patch"
            echo "$patchdir/misc/0001-hardened.patch"
            ;;
        rt-bore)
            [ -f "$patchdir/misc/0001-rt-i915.patch" ] || die "missing RT patch"
            echo "$patchdir/misc/0001-rt-i915.patch"
            ;;
    esac
}

cachyos_summary() {
    require_pkgbuild

    echo "Kernel profile: ${KERNEL_PROFILE:-ps5-cachyos-bore}"
    echo "Kernel base:    ${KERNEL_BASE:-cachyos}"
    echo "Package name:   ${KERNEL_PACKAGE_NAME:-linux-ps5-cachyos-bore}"
    echo "CachyOS pkg repo:   $CACHYOS_PKG_REPO"
    echo "CachyOS pkg ref:    $CACHYOS_PKG_REF"
    echo "CachyOS pkgdir: $CACHYOS_PKGDIR"
    echo "CachyOS patch repo: $CACHYOS_PATCH_REPO"
    echo "CachyOS patch ref:  $CACHYOS_PATCH_REF"
    echo "CachyOS patches:${CACHYOS_PATCHDIR}"
    [ -n "${CACHYOS_EXPECTED_MAJOR:-}" ] && echo "Expected major:  $CACHYOS_EXPECTED_MAJOR"
    echo "CachyOS version: $(cachyos_pkgver)-$(cachyos_pkgrel)"
    echo "CachyOS srcname: $(cachyos_srcname)"
    echo "CachyOS source:  $(cachyos_source_url)"
    echo "CachyOS major:   $(cachyos_major)"
    echo "Scheduler:       ${CACHYOS_SCHED:-bore}"
    echo "Patch manifest:"
    emit_cachyos_patch_manifest | sed 's/^/  /'
}

case "$cmd" in
    cachyos-sync)
        sync_cachyos_inputs
        ;;
    cachyos-summary)
        cachyos_summary
        ;;
    cachyos-patches)
        emit_cachyos_patch_manifest
        ;;
    cachyos-source-url)
        cachyos_source_url
        ;;
    cachyos-srcname)
        cachyos_srcname
        ;;
    cachyos-pkgrel)
        cachyos_pkgrel
        ;;
    cachyos-version)
        cachyos_pkgver
        ;;
    *)
        die "unknown command: $cmd"
        ;;
esac
