#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Installs the toolchain from snapshot.debian.org at a fixed date. The
# snapshot's InRelease files are pinned by sha256, the installed package
# set must equal build-env/packages-<arch>.lock, and the lock's hash goes
# to /etc/a7s-linux-mainline-build-env.lock (MANIFEST names it).
#
# Container only: it rewrites the apt sources as root. Run it through
# build-env/Containerfile.
#
# Environment (all optional):
#   APT_PROXY           http proxy for the snapshot
#   A7S_EXTRA_PACKAGES  packages for tools outside the build (installed
#                       after the lock check, so they cannot change it)
#   A7S_WRITE_LOCK=1    write packages-<arch>.lock instead of checking it
#                       (after a change of snapshot date or base image)
#   A7S_IN_CONTAINER=1  for a container that has neither marker file (a
#                       docker build step); the Containerfile sets it
set -eu

if [ ! -e /.dockerenv ] && [ ! -e /run/.containerenv ] \
   && [ "${A7S_IN_CONTAINER:-0}" != 1 ]; then
  echo "install.sh: runs only inside a container -- it rewrites the apt sources as root." >&2
  echo "install.sh: build the environment with build-env/Containerfile instead." >&2
  exit 1
fi

SNAPSHOT=20260920T000000Z
HERE=$(cd "$(dirname "$0")" && pwd)
ARCH=$(dpkg --print-architecture)
LOCK="$HERE/packages-$ARCH.lock"
case "$ARCH" in
  # The kernel is cross compiled; the libc is for the arm64 build tools in
  # kernel-a7s-devel.
  amd64) CROSS="gcc-aarch64-linux-gnu libc6-dev-arm64-cross" ;;
  arm64) CROSS= ;;                        # the native gcc builds it
  *) echo "install.sh: no lock for architecture $ARCH (amd64 or arm64)" >&2; exit 1 ;;
esac
[ -f "$LOCK" ] || [ "${A7S_WRITE_LOCK:-0}" = 1 ] \
  || { echo "install.sh: missing $LOCK" >&2; exit 1; }

# The base image has no CA certificates, so apt reaches the snapshot over
# http. That is no weaker: the InRelease files are pinned by sha256 below,
# and they pin every index and package by its hash.
scheme=http
if [ -n "${APT_PROXY:-}" ]; then
  echo "Acquire::http::Proxy \"$APT_PROXY\";" > /etc/apt/apt.conf.d/01proxy
else
  rm -f /etc/apt/apt.conf.d/01proxy
fi

rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*
cat > /etc/apt/sources.list.d/snapshot.sources <<SOURCES
Types: deb
URIs: $scheme://snapshot.debian.org/archive/debian/$SNAPSHOT/
Suites: trixie trixie-updates
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
Check-Valid-Until: no

Types: deb
URIs: $scheme://snapshot.debian.org/archive/debian-security/$SNAPSHOT/
Suites: trixie-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
Check-Valid-Until: no
SOURCES

# snapshot.debian.org is rate limited and drops connections at times.
cat > /etc/apt/apt.conf.d/10snapshot <<'APT'
Acquire::Retries "5";
Acquire::http::Timeout "60";
APT

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

# The indexes must be exactly the snapshot's.
check_inrelease() {  # <path fragment> <sha256>
  f=$(ls /var/lib/apt/lists/*"$1"_InRelease 2>/dev/null | head -1)
  [ -n "$f" ] || { echo "install.sh: no InRelease for $1" >&2; exit 1; }
  echo "$2  $f" | sha256sum -c --quiet - \
    || { echo "install.sh: $f is not the pinned snapshot index" >&2; exit 1; }
}
check_inrelease "archive_debian_${SNAPSHOT}_dists_trixie" \
  0584fba32e13e0ab8285fb16c27adea1ec03a73669c18702821094fd6ca86675
check_inrelease "archive_debian_${SNAPSHOT}_dists_trixie-updates" \
  f1af67a2b196298616017dbe7f28e9bbabf1e35a92ddf4bb9224c9ee9394358f
check_inrelease "archive_debian-security_${SNAPSHOT}_dists_trixie-security" \
  bb2562ee092fbff863dd88ee9d60fdf654de5e3b97ed19cd302932d436e49a95

apt-get install -y -qq --no-install-recommends \
  build-essential $CROSS bc bison flex libssl-dev libelf-dev \
  kmod cpio xz-utils gnupg curl ca-certificates git patch file python3 rpm

# The installed set must be exactly the locked one.
dpkg-query -W -f '${Package}=${Version}:${Architecture}\n' | sort > /etc/a7s-linux-mainline-build-env.lock
if [ "${A7S_WRITE_LOCK:-0}" = 1 ]; then
  cp /etc/a7s-linux-mainline-build-env.lock "$LOCK"
  echo "install.sh: wrote $LOCK"
elif ! cmp -s /etc/a7s-linux-mainline-build-env.lock "$LOCK"; then
  echo "install.sh: the installed packages differ from build-env/packages-$ARCH.lock:" >&2
  diff "$LOCK" /etc/a7s-linux-mainline-build-env.lock >&2 || true
  exit 1
fi

if [ -n "${A7S_EXTRA_PACKAGES:-}" ]; then
  # shellcheck disable=SC2086
  apt-get install -y -qq --no-install-recommends $A7S_EXTRA_PACKAGES
fi
