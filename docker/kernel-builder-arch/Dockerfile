FROM archlinux:latest

# pacman 7+ sandbox doesn't work in Docker containers
RUN echo 'DisableSandbox' >> /etc/pacman.conf

# Kernel compile + packaging tools, matching the GitHub Actions Arch container.
RUN pacman -Syu --noconfirm && pacman -S --noconfirm --needed \
    base-devel bc bison flex elfutils openssl python rsync git ccache \
    pahole zstd libarchive kmod cpio gawk xz && \
    pacman -Scc --noconfirm

WORKDIR /out/staging

# Kernel source may be bind-mounted at /src.
# Pre-built artifacts may be bind-mounted at /out/staging.
# Output packages go to /out

COPY docker/kernel-builder-arch/build.sh /build.sh
COPY docker/kernel-builder-arch/install.sh /install.sh
RUN chmod +x /build.sh

CMD ["/build.sh"]
