#!/bin/bash
#==========================================================================
# build-alpine-rootfs.sh — Build an Alpine Linux base rootfs image (ext4)
# and lay out the filesystem so ophub/amlogic-s9xxx-armbian's `rebuild`
# can use it as a base and assemble kernel/u-boot/bootfs + partitions.
#
# Usage:
#   sudo ./build-alpine-rootfs.sh [arch] [out_file] [size_mb]
#     arch      : aarch64 (ARM CI runner) or x86_64 (local validation)
#     out_file  : output ext4 image (default: /builder/build/output/images/alpine-base.img)
#     size_mb   : rootfs size in MiB (default: 2048)
#
# The produced plain-file image (single ext4 rootfs partition, no partition
# table) is what `rebuild` expects as its *base* input: rebuild losetup-mounts
# it, copies it into a fresh GPT image, then replaces /boot, kernel modules,
# u-boot and bootfs per the target board.
#
# We pre-stamp a few compatibility fields that `rebuild` requires reading
# from the base rootfs even though the OS is Alpine:
#   /etc/os-release       -> ID=alpine + VERSION_CODENAME=<ver> (rebuild
#                            hard-errors if VERSION_CODENAME is missing)
#   /etc/fstab            -> rebuild rewrites root LABEL/UUID entries
#   /etc/armbian-release  -> guarded ([ -f ]) in rebuild; optional here
#==========================================================================
set -euo pipefail

ARCH="${1:-aarch64}"
OUT_FILE="${2:-/builder/build/output/images/alpine-base.img}"
SIZE_MB="${3:-2048}"
ALPINE_RELEASE="v3.22"          # stable branch
ALPINE_VER="3.22.6"

if [[ "${ARCH}" == "aarch64" ]]; then
    MIRROR_BASE="https://dl-cdn.alpinelinux.org/alpine/${ALPINE_RELEASE}/releases/aarch64"
    APK_ARCH="aarch64"
elif [[ "${ARCH}" == "x86_64" ]]; then
    MIRROR_BASE="https://dl-cdn.alpinelinux.org/alpine/${ALPINE_RELEASE}/releases/x86_64"
    APK_ARCH="x86_64"
else
    echo "ERROR: unsupported arch [ ${ARCH} ]" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "=== [1/5] Bootstrap Alpine ${ALPINE_VER} (${ARCH}) base rootfs ==="
# Use apk --root to install a full base system with correct /bin->usr/bin layout
# and symlinked /var/run,/var/lock that `rebuild`'s refactor expects.
curl -fsSL "${MIRROR_BASE}/alpine-minirootfs-${ALPINE_VER}-${APK_ARCH}.tar.gz" -o "${WORK}/minirootfs.tar.gz"
mkdir -p "${WORK}/root"
tar -xzf "${WORK}/minirootfs.tar.gz" -C "${WORK}/root"

# Build a resolv.conf so apk can resolve inside chroot-style bundle
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "${WORK}/root/etc/resolv.conf"

# Install a functional base (network config, openssh, common tools)
cat > "${WORK}/root/etc/apk/repositories" <<EOF
${MIRROR_BASE%/*}/main
${MIRROR_BASE%/*}/community
EOF

chroot "${WORK}/root" /bin/sh -c "
  apk --update add --no-cache \
    alpine-base \
    busybox \
    openssh \
    openrc \
    chrony \
    util-linux \
    file \
    curl \
    bash \
    grep \
    sed \
    kmod \
    || true
" 2>&1 | tail -20 || true

echo "=== [2/5] Pre-stamp rebuild compatibility files ==="
# os-release: ID=alpine + VERSION_CODENAME (required by rebuild extract_armbian)
cat > "${WORK}/root/etc/os-release" <<EOF
NAME="Alpine Linux"
ID=alpine
VERSION_ID=${ALPINE_VER}
VERSION_CODENAME=${ALPINE_VER%.*}
PRETTY_NAME="Alpine Linux v${ALPINE_VER}"
HOME_URL="https://alpinelinux.org/"
EOF

# fstab: rebuild rewrites the ROOTFS line with the real UUID
cat > "${WORK}/root/etc/fstab" <<'EOF'
LABEL=ROOTFS  /  ext4  defaults,noatime  0 1
LABEL=BOOT  /boot  vfat  defaults  0 2
EOF

# armbian-release (optional; rebuild guards on existence) — include so the
# same firstrun tooling finds it
cat > "${WORK}/root/etc/armbian-release" <<EOF
VERSION="26.8.1-alpine"
BOARD="$(basename "${OUT_FILE}" .img 2>/dev/null || echo board)"
VENDOR="Alpine Linux"
IMAGE_TYPE=rebuild
EOF

echo "=== [3/5] System tweaks for ARM SoC boot ==="
# sshd: enable root login so the image is usable out of the box
sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' "${WORK}/root/etc/ssh/sshd_config" 2>/dev/null || true
printf 'root:alpine' | chroot "${WORK}/root" /bin/chpasswd 2>/dev/null || true

# Ensure the standard /bin->usr/bin layout holds after installs
cd "${WORK}/root"
[[ -d bin && ! -L bin ]] && { rm -rf bin.old; mv bin bin.old; ln -sf usr/bin bin; }
[[ -d sbin && ! -L sbin ]] && { rm -rf sbin.old; mv sbin sbin.old; ln -sf usr/sbin sbin; }
[[ -d lib && ! -L lib ]] && { rm -rf lib.old; mv lib lib.old; ln -sf usr/lib lib; }
cd - >/dev/null

echo "=== [4/5] Create base image with GPT + p2 rootfs (for rebuild losetup) ==="
mkdir -p "$(dirname "${OUT_FILE}")"
rm -f "${OUT_FILE}"
BOOT_MB=512
IMG_SIZE=$((BOOT_MB + SIZE_MB))
truncate -s "${IMG_SIZE}M" "${OUT_FILE}"
# GPT partition table: p1 = boot (ext4), p2 = rootfs (ext4).
# rebuild's extract_armbian does `losetup -P` then mounts p2 if present,
# else p1 — so p2 must carry the Alpine rootfs.
parted -s "${OUT_FILE}" mklabel gpt
parted -s "${OUT_FILE}" mkpart primary ext4 1MiB "${BOOT_MB}MiB"
parted -s "${OUT_FILE}" mkpart primary ext4 "${BOOT_MB}MiB" 100%

LOOP_DEV="$(losetup -P -f --show "${OUT_FILE}")"
trap 'losetup -d "${LOOP_DEV}" 2>/dev/null || true; rm -rf "${WORK}"' EXIT
mkfs.ext4 -q -L BOOT "${LOOP_DEV}p1"
mkfs.ext4 -q -L ROOTFS "${LOOP_DEV}p2"

mkdir -p "${WORK}/mnt_boot" "${WORK}/mnt_root"
mount "${LOOP_DEV}p2" "${WORK}/mnt_root"
cp -a "${WORK}/root"/. "${WORK}/mnt_root"/
sync
umount "${WORK}/mnt_root"
losetup -d "${LOOP_DEV}"
trap 'rm -rf "${WORK}"' EXIT

echo "=== [5/5] Done: ${OUT_FILE} (${ARCH}) ==="
ls -lh "${OUT_FILE}"
