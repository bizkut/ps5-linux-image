#!/bin/bash
# Compiles a kernel from /src when available, then packages staged artifacts
# as a pacman .pkg.tar.zst.
# Runs inside Docker as root; packages manually (makepkg refuses root).
set -e

export PATH="/usr/lib/ccache:${PATH}"
export CCACHE_DIR="${CCACHE_DIR:-/ccache}"

if [ -f /src/Makefile ]; then
    cd /src
    make -C tools/objtool clean 2>/dev/null || true

    JOBS="${JOBS:-$(nproc)}"
    make olddefconfig
    make -j"$JOBS" bzImage modules

    echo "=== Staging build artifacts ==="
    rm -rf /out/staging
    mkdir -p /out/staging/boot

    cp arch/x86/boot/bzImage /out/staging/boot/
    cp System.map             /out/staging/
    cp .config                /out/staging/

    make modules_install INSTALL_MOD_PATH=/out/staging INSTALL_MOD_STRIP=1

    KVER=$(make -s kernelrelease)
    rm -f "/out/staging/lib/modules/$KVER/build" \
          "/out/staging/lib/modules/$KVER/source"

    echo "=== Staging kernel headers ==="
    HDR="/out/staging/headers"
    make headers_install INSTALL_HDR_PATH="$HDR/usr"

    export srctree=/src SRCARCH=x86
    CC=gcc HOSTCC=gcc MAKE=make /src/scripts/package/install-extmod-build "$HDR/lib/modules/$KVER/build"

    echo "$KVER" > /out/VERSION
fi

if [ ! -f /out/staging/boot/bzImage ]; then
    echo "Error: no kernel source at /src and no staged artifacts in /out/staging"
    exit 1
fi

# Determine version from staged modules directory
KVER=$(ls /out/staging/lib/modules/)
PKGNAME="${KERNEL_PACKAGE_NAME:-linux-ps5}"
PKGVER="${KVER//-/_}-1"

echo "==> Packaging kernel $KVER as pacman package"

STAGING=$(mktemp -d)

# Copy staged boot artifacts
mkdir -p "$STAGING/boot"
cp /out/staging/boot/bzImage "$STAGING/boot/vmlinuz-$KVER"
cp /out/staging/System.map   "$STAGING/boot/System.map-$KVER"
cp /out/staging/.config      "$STAGING/boot/config-$KVER"

# Copy pre-installed modules (Arch uses /usr/lib/modules)
mkdir -p "$STAGING/usr/lib/modules"
cp -a "/out/staging/lib/modules/$KVER" "$STAGING/usr/lib/modules/"

# Kernel headers (for out-of-tree module builds)
if [ -d /out/staging/headers ]; then
    # UAPI headers (/usr/include/linux/, /usr/include/asm/, etc.)
    cp -a /out/staging/headers/usr "$STAGING/usr"
    # Build headers (/usr/lib/modules/$KVER/build/)
    mkdir -p "$STAGING/usr/lib/modules/$KVER"
    cp -a /out/staging/headers/lib/modules/$KVER/build "$STAGING/usr/lib/modules/$KVER/build"
fi

# Create .INSTALL from template, baking in package name/version
sed "s/__KVER__/$KVER/g; s/__PKGNAME__/$PKGNAME/g" /install.sh > "$STAGING/.INSTALL"

# Create .PKGINFO
BUILDDATE=$(date -u +%s)
INSTALLED_SIZE=$(du -sb "$STAGING" | awk '{print $1}')
cat > "$STAGING/.PKGINFO" << EOF
pkgname = $PKGNAME
pkgbase = $PKGNAME
pkgver = $PKGVER
pkgdesc = PS5 Linux kernel $KVER (image + modules + headers)
url = https://kernel.org
builddate = $BUILDDATE
packager = ps5-linux
size = $INSTALLED_SIZE
arch = x86_64
license = GPL-2.0-only
provides = linux=${KVER%%-*}
provides = linux-headers=${KVER%%-*}
provides = linux-api-headers=${KVER%%-*}
conflict = linux
conflict = linux-headers
conflict = linux-api-headers
conflict = linux-custom
replaces = linux
replaces = linux-headers
replaces = linux-api-headers
replaces = linux-custom
EOF

# Create .MTREE (required by newer pacman)
cd "$STAGING"
LANG=C bsdtar -czf .MTREE --format=mtree \
    --options='!all,use-set,type,uid,gid,mode,time,size,md5,sha256,link' \
    .PKGINFO .INSTALL *

# Build the package
PKGFILE="${PKGNAME}-${PKGVER}-x86_64.pkg.tar.zst"
LANG=C bsdtar -cf - .PKGINFO .INSTALL .MTREE * | zstd -c -T0 > "/out/$PKGFILE"

echo "==> Done: /out/$PKGFILE"
