#!/usr/bin/env bash
# Installs the toolchain of tools/toolchain.env, as root, in a container of its IMAGE. CI runs it
# in the job's container and tools/build-in-container.sh in a local one, so the package list is
# this one. Afterwards dotnet is on PATH and the aarch64 sysroot is /opt/sysroot-aarch64.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tools/toolchain.env
source "$root/tools/toolchain.env"

# The keyring of the image or of the archive day can hold a packager key that has expired since.
# The current keyring, from the live repos, checks the old signatures too. It is not in the
# bytes: the comparison of the bytes is the proof. The image ships no local key to sign the
# keyring's keys with, so --init makes one, and --populate trusts the keys just installed.
pacman -Sy --noconfirm --needed archlinux-keyring
pacman-key --init
pacman-key --populate archlinux
echo "Server = https://archive.archlinux.org/repos/${ALA_DATE}/\$repo/os/\$arch" > /etc/pacman.d/mirrorlist
# One transaction, so that keyring checks every package, and the archive day's older keyring is
# not installed over it.
pacman -Syyuu --noconfirm --needed --ignore archlinux-keyring \
  clang lld llvm compiler-rt gcc binutils glibc zlib linux-api-headers sqlite nodejs xz icu git diffutils
pacman -Q clang lld llvm compiler-rt gcc glibc binutils zlib sqlite

curl -fsSL --retry 3 "https://builds.dotnet.microsoft.com/dotnet/Sdk/${DOTNET_SDK}/dotnet-sdk-${DOTNET_SDK}-linux-x64.tar.gz" -o /tmp/dotnet-sdk.tar.gz
echo "${DOTNET_SDK_SHA512}  /tmp/dotnet-sdk.tar.gz" | sha512sum -c -
mkdir -p /opt/dotnet
tar -xzf /tmp/dotnet-sdk.tar.gz -C /opt/dotnet
rm /tmp/dotnet-sdk.tar.gz
# dotnet finds its SDK from the real path of the link.
ln -sfn /opt/dotnet/dotnet /usr/local/bin/dotnet
dotnet --version

# The 8 packages of tools/sysroot.lock, as one tarball on a pre-release of othavi0/omanotes, named
# here so a fork checks the same asset. tools/sysroot.sh checks each package against the lock;
# SYSROOT_TAR_SHA256 also checks the tarball before tar reads a byte of it.
lock="$(sha256sum "$root/tools/sysroot.lock" | cut -c1-12)"
curl -fsSL --retry 3 "https://github.com/othavi0/omanotes/releases/download/sysroot-${lock}/sysroot-pkgs.tar" -o /tmp/sysroot-pkgs.tar
echo "${SYSROOT_TAR_SHA256}  /tmp/sysroot-pkgs.tar" | sha256sum -c -
mkdir -p /tmp/sysroot-pkgs
tar -xf /tmp/sysroot-pkgs.tar -C /tmp/sysroot-pkgs
SYSROOT_AARCH64=/opt/sysroot-aarch64 "$root/tools/sysroot.sh" /tmp/sysroot-pkgs
rm -rf /tmp/sysroot-pkgs /tmp/sysroot-pkgs.tar
