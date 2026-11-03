#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
#
# The build steps of a7s-linux-mainline. They run inside the builder
# container, which ./build.sh at the top of the repository starts:
#
#   ./build.sh [stage...]        default: all stages in order
#
# Paths below are relative to the top of the repository.
#
# Stages:
#   version   print the pinned kernel version and exit
#   fetch     download the kernel.org tarball and its signature
#   verify    check the pinned sha256 and the kernel.org signature (a
#             release candidate: Linus' tag and the tree, see below)
#   prepare   unpack the pristine tarball and apply patches/series
#   config    configure the kernel: the arm64 defconfig of the patched tree
#   build     build Image, device trees and modules
#   package   collect the results in out/ with MANIFEST and SHA256SUMS
#
# The source is the unmodified kernel.org tarball plus patches/series,
# applied at fuzz 0. The build runs out of tree (O=); the source tree is
# checked to be unchanged afterwards.
#
# A release candidate has no signed tarball. Then verify checks Linus'
# signature on the tag in source/, that the tag names the commit there,
# and that kernel.org's snapshot tarball holds exactly that commit's tree.
#
# Config: the arm64 defconfig of the patched tree, plus an optional
# A7S_CONFIG_FRAGMENT. Options that make the output depend on the host
# are switched off or refused (see stage_config).
#
# Environment (all optional):
#   A7S_KERNEL_MIRROR  base URL serving the same files as kernel.org; they
#                      are verified exactly as from kernel.org, so a mirror
#                      is transport only
#   A7S_WORK, A7S_OUT  work and output directories (default: ./work, ./out)
#   A7S_W1=1           build with W=1 and write the warnings to
#                      $A7S_WORK/warnings.txt
#   A7S_LOCALVERSION   kernel local version (default: -a7s)
#   A7S_CONFIG_FRAGMENT  config fragment (CONFIG_ lines) merged after the
#                      defconfig; see above
#   JOBS               parallel jobs (default: all CPUs)
#   SOURCE_DATE_EPOCH  build timestamp; default: the timestamp kernel.org
#                      gave the tarball's files (fixed by the pinned sha256)

set -euo pipefail

# --- pins: the one place for the kernel version --------------------------
KERNEL_VERSION="7.3"
KERNEL_SHA256="87363c24f10e06321eb362765521094e94471f6bff8bce2d6b3e40f39f004953"
# Greg Kroah-Hartman, Linux kernel stable release signing key: it signs the
# tarballs of mainline and stable releases alike.
KERNEL_SIGNER_FPR="647F28654894E3BD457199BE38DBBDC86092693E"
KERNEL_SIGNER_KEY="keys/linux-stable-signing-key.asc"
# Linus Torvalds: signs the mainline tags, a release candidate's only
# signature.
KERNEL_TAG_SIGNER_FPR="ABAF11C65A2970B130ABE3C479BE3E4300411886"
KERNEL_TAG_SIGNER_KEY="keys/linux-torvalds-signing-key.asc"

TOP=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mkdir -p "${A7S_WORK:-$TOP/work}" && cd "${A7S_WORK:-$TOP/work}" && pwd)
OUT=$(mkdir -p "${A7S_OUT:-$TOP/out}" && cd "${A7S_OUT:-$TOP/out}" && pwd)
SRC="$WORK/src"
OBJ="$WORK/obj"
DL="$WORK/dl"
case "$KERNEL_VERSION" in
  [0-9]*.[0-9]*-rc[0-9]*)
    RC=1
    TARBALL="linux-${KERNEL_VERSION}.tar.gz"
    SIGNATURE=""
    TAG_OBJECT="source/v${KERNEL_VERSION}.tag"
    COMMIT_OBJECT="source/v${KERNEL_VERSION}.commit"
    KERNEL_URL="${A7S_KERNEL_MIRROR:-https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/snapshot}"
    ;;
  *)
    RC=0
    TARBALL="linux-${KERNEL_VERSION}.tar.xz"
    SIGNATURE="linux-${KERNEL_VERSION}.tar.sign"
    KERNEL_URL="${A7S_KERNEL_MIRROR:-https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_VERSION%%.*}.x}"
    ;;
esac
# make target of the configuration (see the top of this file)
DEFCONFIG="defconfig"
LOCALVERSION="${A7S_LOCALVERSION--a7s}"

if [ "$(uname -m)" = aarch64 ]; then
  CROSS_COMPILE="${CROSS_COMPILE-}"
else
  CROSS_COMPILE="${CROSS_COMPILE-aarch64-linux-gnu-}"
fi
JOBS="${JOBS:-$(nproc)}"

# --- reproducibility ------------------------------------------------------
# The build timestamp is a property of the input, not of the checkout: by
# default it is the time kernel.org stamped on the tarball's files, which
# the pinned sha256 fixes. Same inputs give the same timestamp in a full
# clone, a shallow clone or an unpacked archive; no git is needed.
export KBUILD_BUILD_USER="builder"
export KBUILD_BUILD_HOST="a7s-linux-mainline"
# Without it every relink bumps the "#N" build counter in the version string.
export KBUILD_BUILD_VERSION=1
export LC_ALL=C TZ=UTC
umask 022
# Options whose presence depends on the host toolchain, not on the input:
# the config stage switches them off and checks that they stay off.
HOST_DEPENDENT_OPTIONS=(LOCALVERSION_AUTO GCC_PLUGINS DEBUG_INFO_BTF IKHEADERS RUST)

log() { printf '=== %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ "$KERNEL_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+|-rc[0-9]+)?$ ]] \
  || die "KERNEL_VERSION is not X.Y, X.Y.Z or X.Y-rcN: '$KERNEL_VERSION'"

# The release string make derives from the Makefile: a release candidate
# and a first release carry SUBLEVEL 0 (7.3-rc5 -> 7.3.0-rc5, 7.3 -> 7.3.0).
kernel_release() {
  case "$KERNEL_VERSION" in
    *-rc*)   echo "${KERNEL_VERSION%-rc*}.0-rc${KERNEL_VERSION##*-rc}$LOCALVERSION" ;;
    *.*.*)   echo "$KERNEL_VERSION$LOCALVERSION" ;;
    *)       echo "$KERNEL_VERSION.0$LOCALVERSION" ;;
  esac
}

# git, and nothing that could change a file while git hashes it: no system
# or user configuration, no line-ending conversion, and attributes read from
# the empty tree instead of the .gitattributes files in the work tree.
git_plain() {  # <git dir> <git arguments...>, run in the work tree
  local d=$1; shift
  env -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_ATTR_NOSYSTEM=1 \
    GIT_ATTR_SOURCE=4b825dc642cb6eb9a060e54bf8d69288fbee4904 \
    GIT_DIR="$d" GIT_INDEX_FILE="$d/index" GIT_WORK_TREE=. \
    git -c core.autocrlf=false -c core.symlinks=true -c core.filemode=true \
      -c core.attributesFile=/dev/null "$@"
}

git_init() {  # <dir>: an empty repository with SHA-1 objects, as linux.git
  env GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    git init -q --bare --object-format=sha1 "$1"
}

set_build_time() {  # after prepare
  if [ -z "${SOURCE_DATE_EPOCH:-}" ]; then
    [ -s "$WORK/source-date-epoch" ] || die "no source timestamp -- run the prepare stage first"
    SOURCE_DATE_EPOCH=$(cat "$WORK/source-date-epoch")
  fi
  export SOURCE_DATE_EPOCH
  export KBUILD_BUILD_TIMESTAMP="$(LC_ALL=C date -u -d "@$SOURCE_DATE_EPOCH")"
}

kmake() {
  set_build_time
  make -C "$SRC" O="$OBJ" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" \
    LOCALVERSION="$LOCALVERSION" \
    KCFLAGS="-fdebug-prefix-map=$SRC= -fdebug-prefix-map=$OBJ=." \
    KAFLAGS="-fdebug-prefix-map=$SRC= -fdebug-prefix-map=$OBJ=." \
    -j"$JOBS" "$@"
}

tree_hash() {  # <dir>: one hash over every entry's type, mode, path, link target and content
  (cd "$1" && {
    find . -printf '%y %m %p %l\n' | sort
    find . -type f -print0 | sort -z | xargs -0 sha256sum
  }) | sha256sum | cut -d' ' -f1
}

check_source_unchanged() {
  [ "$(tree_hash "$SRC")" = "$(cat "$WORK/src.treehash")" ] \
    || die "the build changed the source tree"
}

# Every tool the requested stages call, checked before the first one runs:
# a missing tool is named here instead of ending the build half way, or
# silently where a stage hides stderr.
stage_tools() {  # <stage>
  case "$1" in
    fetch)        echo curl ;;
    verify)       if [ "$RC" = 1 ]; then echo gpg git sha256sum tar gzip; else echo gpg xz sha256sum; fi ;;
    prepare)      if [ "$RC" = 1 ]; then echo tar gzip patch; else echo tar xz patch; fi ;;
    config|build) echo make "${CROSS_COMPILE}gcc" flex bison bc perl ;;
    package)      echo make "${CROSS_COMPILE}gcc" tar gzip ;;
  esac
}

preflight() {  # <stage...>
  local s t missing=()
  for s in "$@"; do
    for t in $(stage_tools "$s"); do
      command -v "$t" >/dev/null 2>&1 || [[ " ${missing[*]} " == *" $t "* ]] || missing+=("$t")
    done
  done
  [ ${#missing[@]} = 0 ] || die "missing tools: ${missing[*]} -- run the build through ./build.sh: the builder container has them"
}

series_entries() {  # the patch paths from patches/series, in order
  # awk ends every line with a newline, the last one too: a reader that
  # stops at a line without one would drop the last patch.
  awk '{ sub(/[[:space:]]*#.*/, "") } /[^[:space:]]/' "$TOP/patches/series"
}

stage_version() { echo "$KERNEL_VERSION"; }

stage_fetch() {
  mkdir -p "$DL"
  local f
  for f in "$TARBALL" ${SIGNATURE:+"$SIGNATURE"}; do
    [ -s "$DL/$f" ] && continue
    log "fetch $KERNEL_URL/$f"
    curl -fL --retry 3 -o "$DL/$f.part" "$KERNEL_URL/$f"
    mv "$DL/$f.part" "$DL/$f"
  done
}

stage_verify() {
  log "sha256 of $TARBALL"
  echo "$KERNEL_SHA256  $DL/$TARBALL" | sha256sum -c --quiet - \
    || die "$TARBALL does not match the pinned sha256"
  if [ "$RC" = 1 ]; then
    verify_tag
    log "unpack $TARBALL to check its tree"
    rm -rf "$WORK/verify"
    mkdir -p "$WORK/verify"
    tar -C "$WORK/verify" --strip-components=1 -xzf "$DL/$TARBALL"
    check_tree "$WORK/verify"
    rm -rf "$WORK/verify"
    return
  fi

  # The signature covers the uncompressed tar, not the .xz.
  log "signature of $TARBALL (key $KERNEL_SIGNER_FPR)"
  local gnupg status
  gnupg=$(mktemp -d)
  gpg --homedir "$gnupg" --batch --quiet --import "$TOP/$KERNEL_SIGNER_KEY" 2>/dev/null \
    || die "gpg cannot import $KERNEL_SIGNER_KEY"
  status=$(xz -dc "$DL/$TARBALL" \
    | gpg --homedir "$gnupg" --batch --status-fd 1 --verify "$DL/$SIGNATURE" - 2>/dev/null || true)
  rm -rf "$gnupg"
  printf '%s\n' "$status" | awk '$2 == "VALIDSIG" { print $NF }' | grep -qx "$KERNEL_SIGNER_FPR" \
    || die "no valid signature by $KERNEL_SIGNER_FPR on $TARBALL"
  printf '%s\n' "$status" | grep -q '^\[GNUPG:\] GOODSIG ' \
    || die "signature on $TARBALL is not GOODSIG (expired or revoked key?)"
}

# A release candidate: Linus' signature on the tag, checked by git
# verify-tag with the same two conditions as a tarball's signature, and
# the tag naming exactly this version and the commit in source/.
verify_tag() {
  local tag="$TOP/$TAG_OBJECT" commit="$TOP/$COMMIT_OBJECT" g id status
  [ -f "$tag" ] && [ -f "$commit" ] || die "a release candidate needs $TAG_OBJECT and $COMMIT_OBJECT"
  log "signature on tag v$KERNEL_VERSION (key $KERNEL_TAG_SIGNER_FPR)"
  g=$(mktemp -d)
  mkdir -m 700 "$g/gnupg"
  git_init "$g/repo"
  gpg --homedir "$g/gnupg" --batch --quiet --import "$TOP/$KERNEL_TAG_SIGNER_KEY" 2>/dev/null \
    || { rm -rf "$g"; die "gpg cannot import $KERNEL_TAG_SIGNER_KEY"; }
  id=$(git_plain "$g/repo" hash-object -w -t tag "$tag") \
    || { rm -rf "$g"; die "$TAG_OBJECT is not a tag object"; }
  # verify-tag writes gpg's status lines to stderr.
  status=$(GNUPGHOME="$g/gnupg" git_plain "$g/repo" -c gpg.program=gpg verify-tag --raw "$id" 2>&1 >/dev/null || true)
  id=$(git_plain "$g/repo" hash-object -t commit "$commit") || id=
  rm -rf "$g"
  printf '%s\n' "$status" | awk '$2 == "VALIDSIG" { print $NF }' | grep -qx "$KERNEL_TAG_SIGNER_FPR" \
    || die "no valid signature by $KERNEL_TAG_SIGNER_FPR on $TAG_OBJECT"
  printf '%s\n' "$status" | grep -q '^\[GNUPG:\] GOODSIG ' \
    || die "signature on $TAG_OBJECT is not GOODSIG (expired or revoked key?)"
  [ -n "$id" ] && [ "$(sed -n 1,3p "$tag")" = "$(printf 'object %s\ntype commit\ntag v%s' "$id" "$KERNEL_VERSION")" ] \
    || die "$TAG_OBJECT is not the tag v$KERNEL_VERSION of the commit in $COMMIT_OBJECT"
  log "tag v$KERNEL_VERSION: commit $(sed -n '1s/^object //p' "$tag"), tree $(source_tree)"
}

source_tree() {  # the tree of the tagged commit
  sed -n '1s/^tree \([0-9a-f]\{40\}\)$/\1/p' "$TOP/$COMMIT_OBJECT"
}

# The unpacked tarball must be exactly the tagged commit's tree: every file,
# symlink and executable bit as git records them, nothing more, nothing
# less. git skips a path it refuses to track (.git/, GIT~1/ ...) with a
# warning only, and records no directory of its own: so every file and link
# must also be in the index, and the directories must be the tree's.
# Hashes only; no file is stored.
check_tree() {  # <unpacked tarball>
  local dir=$1 want got odd g
  want=$(source_tree)
  [ -n "$want" ] || die "$COMMIT_OBJECT has no tree line"
  odd=$(cd "$dir" && find . ! -type f ! -type l ! -type d | head -3)
  [ -z "$odd" ] || die "$TARBALL holds files that are neither file, link nor directory: $odd"
  g=$(mktemp -d)
  git_init "$g/repo"
  (cd "$dir" && find . \( -type f -o -type l \) -print0 | sed -z 's#^\./##' | LC_ALL=C sort -z) > "$g/files"
  (cd "$dir" && find . -mindepth 1 -type d -print0 | sed -z 's#^\./##' | LC_ALL=C sort -z) > "$g/dirs"
  got=$(cd "$dir" && git_plain "$g/repo" update-index --add --info-only -z --stdin < "$g/files" 2>/dev/null \
        && git_plain "$g/repo" write-tree --missing-ok) || got=
  if [ "$got" = "$want" ]; then
    (cd "$dir" && git_plain "$g/repo" ls-files -z | LC_ALL=C sort -z) > "$g/indexed" \
      && (cd "$dir" && git_plain "$g/repo" ls-tree -r -d -z --name-only "$got" | LC_ALL=C sort -z) > "$g/treedirs" \
      && cmp -s "$g/files" "$g/indexed" && cmp -s "$g/dirs" "$g/treedirs" \
      || got="$want, but with paths git does not track"
  fi
  rm -rf "$g"
  [ "$got" = "$want" ] \
    || die "$TARBALL is not the tree of tag v$KERNEL_VERSION (tree ${got:-?}, signed $want)"
  log "pristine tree $got = tag v$KERNEL_VERSION"
}

stage_prepare() {
  # Checked again: prepare may run without verify, on a cached tarball.
  echo "$KERNEL_SHA256  $DL/$TARBALL" | sha256sum -c --quiet - \
    || die "$TARBALL does not match the pinned sha256 (run fetch verify)"
  log "unpack pristine $TARBALL"
  rm -rf "$SRC" "$OBJ"
  mkdir -p "$SRC"
  if [ "$RC" = 1 ]; then
    tar -C "$SRC" --strip-components=1 -xzf "$DL/$TARBALL"
  else
    tar -C "$SRC" --strip-components=1 -xJf "$DL/$TARBALL"
  fi
  # Taken before any patch touches a file.
  stat -c %Y "$SRC/Makefile" > "$WORK/source-date-epoch"

  local p n=0
  while IFS= read -r p; do
    [ -f "$TOP/patches/$p" ] || die "patches/series names a missing file: $p"
    patch -d "$SRC" -p1 --fuzz=0 --batch --forward --dry-run --no-backup-if-mismatch -s < "$TOP/patches/$p" >/dev/null \
      || die "does not apply at fuzz 0 (regenerate it): $p"
    patch -d "$SRC" -p1 --fuzz=0 --batch --forward --no-backup-if-mismatch -s < "$TOP/patches/$p" >/dev/null
    n=$((n + 1))
  done < <(series_entries)
  log "applied $n patches"
  tree_hash "$SRC" > "$WORK/src.treehash"
}

stage_config() {
  mkdir -p "$OBJ"
  log "config: arm64 $DEFCONFIG"
  kmake "$DEFCONFIG" >/dev/null
  # The fragment is kept in the work directory, so that the package stage
  # names the one this configuration was made with.
  rm -f "$WORK/config-fragment"
  if [ -n "${A7S_CONFIG_FRAGMENT:-}" ]; then
    [ -f "$A7S_CONFIG_FRAGMENT" ] || die "A7S_CONFIG_FRAGMENT: no file $A7S_CONFIG_FRAGMENT"
    log "config: + fragment $A7S_CONFIG_FRAGMENT"
    cp "$A7S_CONFIG_FRAGMENT" "$WORK/config-fragment"
    "$SRC/scripts/kconfig/merge_config.sh" -m -O "$OBJ" "$OBJ/.config" "$WORK/config-fragment" >/dev/null
  fi
  local o off=()
  for o in "${HOST_DEPENDENT_OPTIONS[@]}"; do off+=(-d "$o"); done
  "$SRC/scripts/config" --file "$OBJ/.config" "${off[@]}"
  kmake olddefconfig >/dev/null
  [ ! -f "$WORK/config-fragment" ] || check_config_fragment "$WORK/config-fragment"
  check_reproducible_config
}

# Every setting of a fragment must be in the configuration as written:
# Kconfig drops a setting whose dependencies are not met without a word, and
# the host-dependent options above stay off whatever a fragment says.
check_config_fragment() {  # <fragment>
  local line bad=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      CONFIG_*=*|'# CONFIG_'*' is not set')
        grep -qxF -- "$line" "$OBJ/.config" || bad="$bad"$'\n'"  $line" ;;
    esac
  done < "$1"
  [ -z "$bad" ] || die "config fragment settings that did not take:$bad"
}

# Settings that would make two builds of the same input differ, or that
# depend on what the host has installed rather than on the input: a
# host-dependent option that Kconfig turns back on, or one of the others
# enabled by a defconfig patch in the series.
check_reproducible_config() {
  local bad="" o
  for o in "${HOST_DEPENDENT_OPTIONS[@]}"; do
    grep -qx "CONFIG_$o=y" "$OBJ/.config" && bad="$bad $o"
  done
  grep -q '^CONFIG_RANDSTRUCT_\(FULL\|PERFORMANCE\)=y' "$OBJ/.config" && bad="$bad RANDSTRUCT"
  grep -q '^CONFIG_MODULE_COMPRESS_\(GZIP\|XZ\|ZSTD\)=y' "$OBJ/.config" && bad="$bad MODULE_COMPRESS"
  # MODULE_SIG with the default key generates a random key at build time.
  if grep -qx 'CONFIG_MODULE_SIG=y' "$OBJ/.config" \
     && grep -qx 'CONFIG_MODULE_SIG_KEY="certs/signing_key.pem"' "$OBJ/.config"; then
    bad="$bad MODULE_SIG(generated-key)"
  fi
  [ -z "$bad" ] || die "config enables non-reproducible options:$bad"
}

stage_build() {
  log "build Image, dtbs, modules (jobs: $JOBS)"
  local w=()
  [ "${A7S_W1:-0}" = 1 ] && w=(W=1)
  # stderr goes to the terminal and, completely, to build.stderr before the
  # next line runs (a process substitution would still be writing).
  # --output-sync=target: each target's output comes out in one piece. In
  # parallel, compilers and dtc write a message in several parts, and lines
  # of different jobs interleave -- one such line is a "new" warning.
  { kmake --output-sync=target "${w[@]}" Image dtbs modules 2>&1 1>&3 \
      | tee "$WORK/build.stderr" >&2; } 3>&1

  if [ "${A7S_W1:-0}" = 1 ]; then
    # Compiler and dtc warnings without line/column and build paths, with a
    # count per distinct warning, so two trees can be compared and a second
    # occurrence of a known warning still shows.
    { grep -E ': warning: |: Warning \(' "$WORK/build.stderr" || true; } \
      | sed -E -e "s#$SRC/##g" -e "s#$OBJ/##g" -e 's#^([^:]+):[0-9][0-9.:-]*:#\1:#' \
      | sort | uniq -c | sed -E 's/^ +//' > "$WORK/warnings.txt"
    log "$(wc -l < "$WORK/warnings.txt") distinct warnings (W=1)"
  fi

  check_source_unchanged
  local rel
  rel=$(cat "$OBJ/include/config/kernel.release")
  [ "$rel" = "$(kernel_release)" ] \
    || die "kernel.release is '$rel', expected '$(kernel_release)'"
}

stage_package() {
  set_build_time
  local rel mod
  rel=$(cat "$OBJ/include/config/kernel.release")
  # Clear out/ only when it is ours: empty, or holding a previous MANIFEST.
  if [ -n "$(ls -A "$OUT")" ] && [ ! -f "$OUT/MANIFEST" ]; then
    die "$OUT is not empty and holds no MANIFEST -- refusing to clear it (set A7S_OUT)"
  fi
  rm -rf "${OUT:?}"/* "$WORK/modroot"
  cp "$OBJ/arch/arm64/boot/Image" "$OUT/Image"
  cp "$OBJ/.config" "$OUT/config-$rel"
  # Every result is a single file, so SHA256SUMS covers exactly what out/
  # holds.
  (cd "$OBJ/arch/arm64/boot/dts" && find allwinner -name '*.dtb' -print0 | sort -z \
    | tar --format=gnu --null -T - --mtime="@$SOURCE_DATE_EPOCH" \
        --owner=0 --group=0 --numeric-owner -cf -) | gzip -n -9 > "$OUT/dtbs-$rel.tar.gz"

  kmake INSTALL_MOD_PATH="$WORK/modroot" modules_install >/dev/null
  mod="$WORK/modroot/lib/modules/$rel"
  rm -f "$mod/build" "$mod/source"
  tar -C "$WORK/modroot" --format=gnu --sort=name --mtime="@$SOURCE_DATE_EPOCH" \
    --owner=0 --group=0 --numeric-owner -cf - lib | gzip -n -9 > "$OUT/modules-$rel.tar.gz"

  {
    echo "kernel=$KERNEL_VERSION"
    echo "kernel.release=$rel"
    echo "tarball.sha256=$KERNEL_SHA256"
    if [ "$RC" = 1 ]; then
      echo "tag.commit=$(sed -n '1s/^object //p' "$TOP/$TAG_OBJECT")"
      echo "tag.signer=$KERNEL_TAG_SIGNER_FPR"
    else
      echo "tarball.signer=$KERNEL_SIGNER_FPR"
    fi
    echo "series.sha256=$(sha256sum < "$TOP/patches/series" | cut -d' ' -f1)"
    echo "patches=$(series_entries | wc -l)"
    echo "config=arm64 $DEFCONFIG"
    [ ! -f "$WORK/config-fragment" ] \
      || echo "config.fragment.sha256=$(sha256sum < "$WORK/config-fragment" | cut -d' ' -f1)"
    echo "source_date_epoch=$SOURCE_DATE_EPOCH"
    echo "compiler=$("${CROSS_COMPILE}gcc" --version | head -1)"
    echo "binutils=$("${CROSS_COMPILE}ld" --version | head -1)"
    echo "kmod=$(depmod --version | head -1)"
    echo "tar=$(tar --version | head -1)"
    echo "gzip=$(gzip --version | head -1)"
    echo "build-env=$( [ -f /etc/a7s-linux-mainline-build-env.lock ] \
      && sha256sum < /etc/a7s-linux-mainline-build-env.lock | cut -d' ' -f1 || echo none)"
  } > "$OUT/MANIFEST"
  (cd "$OUT" && find . -type f ! -name SHA256SUMS -printf '%P\n' | sort \
    | xargs sha256sum > SHA256SUMS)

  # No build path may survive into anything we ship. A leaked path always
  # names something below $WORK, so the pattern ends in a slash: bare "/work"
  # also matches kernel strings such as "mm/workingset.c".
  local leak
  leak=$(grep -rlaF "$WORK/" "$OUT" "$WORK/modroot" "$OBJ/vmlinux" || true)
  [ -z "$leak" ] || die "build paths leak into: $leak"
  check_source_unchanged
  # The modules are in the tarball now.
  rm -rf "$WORK/modroot"
  log "out: $(wc -l < "$OUT/SHA256SUMS") files, kernel $rel"
}

# Sourced: the settings and functions only, no stage.
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0

stages=("$@")
[ ${#stages[@]} -gt 0 ] || stages=(fetch verify prepare config build package)
preflight "${stages[@]}"
for s in "${stages[@]}"; do
  case "$s" in
    version|fetch|verify|prepare|config|build|package) "stage_$s" ;;
    *) die "unknown stage: $s" ;;
  esac
done
