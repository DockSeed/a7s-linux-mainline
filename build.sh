#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# a7s-linux-mainline: build the kernel for the Radxa Cubie A7S in the pinned
# builder container. This is the only script that runs on the host. It needs
# bash, coreutils and podman or docker; no root and no other host package.
# The build steps are scripts/build.sh, which runs inside the container.
#
#   ./build.sh [<stage>...]       version | fetch | verify | prepare | config |
#                                 build | package (default: all but version)
#   ./build.sh shell [<cmd>...]   a shell (or one command) in the builder
#   ./build.sh clean              remove what the build left behind (see below)
#   ./build.sh --help
#
# Result: ./out/ with MANIFEST and SHA256SUMS.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_REPO="localhost/a7s-linux-mainline-build"
# The base image, as build-env/Containerfile names it.
BASE="$(sed -n 's/^FROM //p' "${REPO}/build-env/Containerfile")"
# In the work directory: WORK_MARK when this script created the directory
# (then clean removes all of it), PULLED_MARK when the build pulled BASE
# (then clean removes BASE too).
WORK_MARK=".a7s-linux-mainline-work"
PULLED_MARK=".a7s-linux-mainline-pulled-base"
# What scripts/build.sh and this script put into a work directory.
WORK_ENTRIES=(dl src obj modroot verify home pc src.treehash source-date-epoch
              config-fragment build.stderr warnings.txt "${PULLED_MARK}" "${WORK_MARK}")

die() { printf 'build.sh: error: %s\n' "$*" >&2; exit 1; }
log() { printf '=== %s\n' "$*" >&2; }

usage() {
  cat <<'USAGE'
Usage:
  ./build.sh [<stage>...]          run stages in the builder container
                                   (default: fetch verify prepare config build package)
  ./build.sh shell [<cmd> [<arg>...]]
                                   interactive shell (or one command) in the builder
  ./build.sh clean                 remove what the build left behind: the work
                                   directory, the builder images, and the base
                                   image if the build pulled it; out/ stays
                                   (use the same A7S_WORK as for the build)
  ./build.sh --help                this text

Stages (scripts/build.sh): version, fetch, verify, prepare, config, build,
package.

Environment read by this script:
  A7S_ENGINE           podman or docker (default: podman if installed, else docker)
  A7S_WORK             work directory on the host (default: ./work)
  A7S_OUT              output directory on the host (default: ./out)
  A7S_CONFIG_FRAGMENT  a config fragment file on the host, merged after the
                       defconfig (see README.md)
Passed into the container when set: A7S_KERNEL_MIRROR, A7S_W1,
A7S_LOCALVERSION, JOBS, SOURCE_DATE_EPOCH.

The first run builds the builder image from build-env/.
USAGE
}

pick_engine() {
  ENGINE="${A7S_ENGINE:-}"
  if [ -z "${ENGINE}" ]; then
    if command -v podman >/dev/null 2>&1; then ENGINE=podman
    elif command -v docker >/dev/null 2>&1; then ENGINE=docker
    else die "neither podman nor docker is installed"; fi
  fi
  case "${ENGINE}" in podman|docker) ;; *) die "A7S_ENGINE must be podman or docker, not '${ENGINE}'" ;; esac
  command -v "${ENGINE}" >/dev/null 2>&1 || die "A7S_ENGINE=${ENGINE}, but ${ENGINE} is not installed"
  # A rootless engine maps the container's root to the invoking user, so what
  # the build writes belongs to the user. A rootful engine would write as
  # root: then the container runs as the invoking user instead.
  ROOTLESS=false
  case "${ENGINE}" in
    podman) [ "$(podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" = true ] && ROOTLESS=true ;;
    docker) docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless && ROOTLESS=true ;;
  esac
  return 0
}

# The image tag is a hash over build-env/: any change to the Containerfile,
# the install script or the lock gives a new tag and a rebuild.
builder_tag() {
  local h
  h="$(cd "${REPO}/build-env" \
       && find . -type f ! -name '*~' -print0 | LC_ALL=C sort -z | xargs -0 sha256sum \
       | sha256sum | cut -c1-16)"
  printf '%s:%s' "${IMAGE_REPO}" "${h}"
}

ensure_builder() {  # <work dir>
  TAG="$(builder_tag)"
  "${ENGINE}" image inspect "${TAG}" >/dev/null 2>&1 && return 0
  log "building the builder image ${TAG} (once per change to build-env/)"
  # Mark before the build: the base is pulled even if a later step fails.
  "${ENGINE}" image inspect "${BASE}" >/dev/null 2>&1 \
    || printf '%s\n' "${BASE}" > "$1/${PULLED_MARK}"
  local opts=()
  # podman: no SELinux separation for the build, and no intermediate images
  # left behind (--layers=false); docker keeps its own build cache.
  [ "${ENGINE}" != podman ] || opts+=(--security-opt label=disable --layers=false)
  "${ENGINE}" build "${opts[@]}" -t "${TAG}" -f "${REPO}/build-env/Containerfile" "${REPO}/build-env" >&2 \
    || die "building the builder image failed"
}

abs_path() {  # <path relative to the repository, or absolute>
  case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "${REPO}" "$1" ;; esac
}

abs_dir() {  # <path>: create it if needed; a directory this script creates
             # gets WORK_MARK when <mark> is "mark"
  local p mark="${2:-}"
  p="$(abs_path "$1")"
  if [ "${mark}" = mark ] && [ ! -e "${p}" ]; then
    mkdir -p "${p}" || die "cannot create ${p}"
    : > "${p}/${WORK_MARK}"
  fi
  mkdir -p "${p}" || die "cannot create ${p}"
  (cd "${p}" && pwd)
}

# Remove what the build left behind, and nothing else: no prune, no other
# image, nothing in out/ (the result), nothing of podman's or docker's own.
clean() {
  local work base="" img kept=()
  work="$(abs_path "${A7S_WORK:-work}")"
  [ ! -f "${work}/${PULLED_MARK}" ] || base="$(cat "${work}/${PULLED_MARK}")"

  if [ -n "${A7S_ENGINE:-}" ] || command -v podman >/dev/null 2>&1 || command -v docker >/dev/null 2>&1; then
    pick_engine
    for img in $("${ENGINE}" images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
                 | grep -F "${IMAGE_REPO}:" | sort -u); do
      log "remove image ${img}"
      "${ENGINE}" rmi "${img}" >/dev/null || kept+=("image ${img} (in use?)")
    done
    if [ -n "${base}" ]; then
      if "${ENGINE}" image inspect "${base}" >/dev/null 2>&1; then
        log "remove base image ${base} (the build pulled it)"
        "${ENGINE}" rmi "${base}" >/dev/null 2>&1 || kept+=("base image ${base} (in use by another image or container)")
      fi
    elif "${ENGINE}" image inspect "${BASE}" >/dev/null 2>&1; then
      kept+=("base image ${BASE} (the build in this work directory did not pull it)")
    fi
    [ "${ENGINE}" != docker ] || kept+=("docker's build cache (docker builder prune clears it, for every build)")
  fi

  if [ -d "${work}" ]; then
    if [ -f "${work}/${WORK_MARK}" ]; then
      log "remove ${work}"
      rm -rf "${work}"
    else
      local e
      for e in "${WORK_ENTRIES[@]}"; do
        [ ! -e "${work}/${e}" ] || { log "remove ${work}/${e}"; rm -rf "${work:?}/${e}"; }
      done
      kept+=("${work} itself (it was not created by this script)")
    fi
  fi
  kept+=("$(abs_path "${A7S_OUT:-out}") (the result)")
  local k
  for k in "${kept[@]}"; do log "kept: ${k}"; done
}

main() {
  local a
  for a in "$@"; do
    case "${a}" in -h|--help|help) usage; exit 0 ;; esac
  done
  if [ "$*" = clean ]; then
    clean
    exit 0
  fi
  # The pinned version, read from scripts/build.sh without a container.
  if [ "$*" = version ]; then
    sed -n 's/^KERNEL_VERSION="\(.*\)"$/\1/p' "${REPO}/scripts/build.sh"
    exit 0
  fi
  # build-env/ has a package lock for amd64 and one for arm64.
  case "$(uname -m)" in
    x86_64|aarch64) ;;
    *) die "the builder container is for x86_64 and aarch64 hosts, not $(uname -m)" ;;
  esac

  pick_engine
  local work out
  work="$(abs_dir "${A7S_WORK:-work}" mark)"
  out="$(abs_dir "${A7S_OUT:-out}")"
  ensure_builder "${work}"

  local run=(run --rm --init
    # SELinux: no relabeling of the user's directories (:Z would change their
    # labels for good); the container runs without SELinux separation instead.
    --security-opt label=disable
    -v "${REPO}:/src:ro"
    -v "${work}:/work"
    -v "${out}:/out"
    -e A7S_WORK=/work -e A7S_OUT=/out -e HOME=/work/home
    -w /src)
  if [ -n "${A7S_CONFIG_FRAGMENT:-}" ]; then
    [ -f "${A7S_CONFIG_FRAGMENT}" ] || die "A7S_CONFIG_FRAGMENT: no file ${A7S_CONFIG_FRAGMENT}"
    run+=(--mount "type=bind,src=$(cd "$(dirname "${A7S_CONFIG_FRAGMENT}")" && pwd)/$(basename "${A7S_CONFIG_FRAGMENT}"),dst=/config-fragment,ro"
          -e A7S_CONFIG_FRAGMENT=/config-fragment)
  fi
  if [ "${ROOTLESS}" = false ] && [ "$(id -u)" != 0 ]; then
    run+=(--user "$(id -u):$(id -g)")
  fi
  if [ -t 0 ] && [ -t 1 ]; then run+=(-it); elif [ "${1:-}" = shell ]; then run+=(-i); fi
  local name
  for name in A7S_KERNEL_MIRROR A7S_W1 A7S_LOCALVERSION JOBS SOURCE_DATE_EPOCH; do
    [ -z "${!name+x}" ] || run+=(-e "${name}=${!name}")
  done
  mkdir -p "${work}/home"

  if [ "${1:-}" = shell ]; then
    shift
    [ "$#" -gt 0 ] || set -- bash
    exec "${ENGINE}" "${run[@]}" "${TAG}" "$@"
  fi
  log "${ENGINE} ($([ "${ROOTLESS}" = true ] && echo rootless || echo rootful)), builder ${TAG}, stages: ${*:-all}"
  exec "${ENGINE}" "${run[@]}" "${TAG}" scripts/build.sh "$@"
}

main "$@"
