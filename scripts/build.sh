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
#   tag-version  print the version a release tag names (7.3 -> 7.3.0)
#   fetch     download the kernel.org tarball and its signature
#   verify    check the pinned sha256 and the kernel.org signature (a
#             release candidate: Linus' tag and the tree, see below)
#   prepare   unpack the pristine tarball and apply patches/series
#   config    configure the kernel: config/a7s_defconfig, checked against
#             the arm64 defconfig of the patched tree (see below)
#   savedefconfig  write work/a7s_defconfig: the arm64 defconfig of the
#             patched tree plus config/kernel-config.assert, in minimal form
#   build     build Image, device trees and modules
#   package   collect the results in out/ with MANIFEST and SHA256SUMS
#   release   after package, with A7S_KERNEL_REVISION: the files of a
#             release in out/release/, the RPMs kernel-a7s,
#             kernel-a7s-common and kernel-a7s-devel among them
#
# The source is the unmodified kernel.org tarball plus patches/series,
# applied at fuzz 0. The build runs out of tree (O=); the source tree is
# checked to be unchanged afterwards.
#
# A release candidate has no signed tarball. Then verify checks Linus'
# signature on the tag in source/, that the tag names the commit there,
# and that kernel.org's snapshot tarball holds exactly that commit's tree.
#
# Config: config/a7s_defconfig, plus an optional A7S_CONFIG_FRAGMENT. The
# file is the arm64 defconfig of the patched tree with the entries of
# config/kernel-config.assert on top, in minimal form; the config stage
# refuses it when it is not. Options that make the output depend on the
# host are switched off or refused (see stage_config).
#
# Environment (all optional):
#   A7S_KERNEL_MIRROR  base URL serving the same files as kernel.org; they
#                      are verified exactly as from kernel.org, so a mirror
#                      is transport only
#   A7S_WORK, A7S_OUT  work and output directories (default: ./work, ./out)
#   A7S_W1=1           build with W=1 and write the warnings to
#                      $A7S_WORK/warnings.txt
#   A7S_LOCALVERSION   kernel local version (default: -a7s)
#   A7S_KERNEL_REVISION  r<n> or t<n>: the release being built, from its
#                      tag (v7.3.0-R1 is r1); the kernel release becomes
#                      7.3.0-a7s-r1. Not together with A7S_LOCALVERSION
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
# The configuration and what it must say (see the top of this file)
DEFCONFIG_FILE="config/a7s_defconfig"
ASSERT_FILE="config/kernel-config.assert"
# The board's device tree, shipped on its own in a release.
BOARD_DTB="allwinner/sun60i-a733-cubie-a7s.dtb"
# What a release carries besides the kernel: the RPM is built from this.
RPM_SPEC="rpm/kernel-a7s.spec"
REVISION="${A7S_KERNEL_REVISION:-}"
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
# Without it every relink bumps the "#N" build counter in the version
# string. A release r<n> has n there.
case "$REVISION" in
  r*) export KBUILD_BUILD_VERSION="${REVISION#r}" ;;
  *)  export KBUILD_BUILD_VERSION=1 ;;
esac
export LC_ALL=C TZ=UTC
umask 022
# Options whose presence depends on the host toolchain, not on the input:
# the config stage switches them off and checks that they stay off.
HOST_DEPENDENT_OPTIONS=(LOCALVERSION_AUTO GCC_PLUGINS DEBUG_INFO_BTF IKHEADERS RUST)

log() { printf '=== %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ "$KERNEL_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+|-rc[0-9]+)?$ ]] \
  || die "KERNEL_VERSION is not X.Y, X.Y.Z or X.Y-rcN: '$KERNEL_VERSION'"

# A release build: the revision from the tag goes into the local version,
# so that two releases of one kernel version install side by side, and its
# number into the "#N" of the version string (1 for a test build).
if [ -n "$REVISION" ]; then
  [[ "$REVISION" =~ ^[rt][1-9][0-9]*$ ]] \
    || die "A7S_KERNEL_REVISION must look like r1 or t1, not '$REVISION'"
  [ -z "${A7S_LOCALVERSION:-}" ] \
    || die "A7S_KERNEL_REVISION and A7S_LOCALVERSION are exclusive"
  LOCALVERSION="-a7s-$REVISION"
fi

# The version make derives from the Makefile: a release candidate and a
# first release carry SUBLEVEL 0 (7.3-rc5 -> 7.3.0-rc5, 7.3 -> 7.3.0). A
# release tag names it: v7.3.0-R1.
kernel_base() {
  case "$KERNEL_VERSION" in
    *-rc*)   echo "${KERNEL_VERSION%-rc*}.0-rc${KERNEL_VERSION##*-rc}" ;;
    *.*.*)   echo "$KERNEL_VERSION" ;;
    *)       echo "$KERNEL_VERSION.0" ;;
  esac
}

# The release string: the version plus the local version.
kernel_release() { echo "$(kernel_base)$LOCALVERSION"; }

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

kmake() {  # O= is $OBJ, or $KOBJ when set
  set_build_time
  make -C "$SRC" O="${KOBJ:-$OBJ}" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" \
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
    config|savedefconfig|build) echo make "${CROSS_COMPILE}gcc" flex bison bc perl ;;
    package)      echo make "${CROSS_COMPILE}gcc" tar gzip find readelf ;;
    release)      echo rpmbuild rpm git tar gzip modinfo sha256sum find readelf ;;
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

# sha256 over the content of the patches, in the order of patches/series.
patches_sha256() {
  local p
  while IFS= read -r p; do cat "$TOP/patches/$p"; done < <(series_entries) \
    | sha256sum | cut -d' ' -f1
}

# The commit of the checkout, or nothing when it is no git checkout.
checkout_commit() {
  git -C "$TOP" -c safe.directory="$TOP" rev-parse -q --verify HEAD 2>/dev/null || true
}

stage_version() { echo "$KERNEL_VERSION"; }
stage_tag_version() { kernel_base; }

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

# The entries of the assert file, one per line: <kind> <argument>.
assert_entries() {
  sed -e 's/[[:space:]]*$//' -e '/^#/d' -e '/^$/d' "$TOP/$ASSERT_FILE"
}

assert_symbol() {  # <kind> <argument>: the CONFIG_ symbol of an entry
  case "$1" in
    y|m) echo "CONFIG_$2" ;;
    line)
      case "$2" in
        'CONFIG_'*=*) echo "${2%%=*}" ;;
        '# CONFIG_'*' is not set') local n=${2#\# }; echo "${n% is not set}" ;;
        *) return 1 ;;
      esac ;;
    *) return 1 ;;
  esac
}

assert_line() {  # <kind> <argument>: the line .config must hold
  case "$1" in y|m) echo "CONFIG_$2=$1" ;; line) echo "$2" ;; esac
}

apply_asserts() {  # <obj dir>: set every entry in its .config
  local kind arg sym args=()
  while read -r kind arg; do
    sym=$(assert_symbol "$kind" "$arg") || die "$ASSERT_FILE: cannot read '$kind $arg'"
    sym=${sym#CONFIG_}
    case "$kind:$arg" in
      y:*)        args+=(--enable "$sym") ;;
      m:*)        args+=(--module "$sym") ;;
      'line:# '*) args+=(--disable "$sym") ;;
      line:*)     args+=(--set-val "$sym" "${arg#*=}") ;;
    esac
  done < <(assert_entries)
  "$SRC/scripts/config" --file "$1/.config" "${args[@]}"
}

# Every entry must be in the configuration as written. A fragment decides
# for the symbols it names (A7S_CONFIG_FRAGMENT, README.md).
check_asserts() {  # <.config> [<fragment>]
  local kind arg sym bad=""
  while read -r kind arg; do
    sym=$(assert_symbol "$kind" "$arg") || die "$ASSERT_FILE: cannot read '$kind $arg'"
    if [ -n "${2:-}" ] && grep -Eq "^(# )?${sym}[= ]" "$2"; then continue; fi
    grep -qxF -- "$(assert_line "$kind" "$arg")" "$1" || bad="$bad"$'\n'"  $kind $arg"
  done < <(assert_entries)
  [ -z "$bad" ] || die "$ASSERT_FILE entries that did not take:$bad"
}

# A configuration in <obj dir>, from config/a7s_defconfig ("a7s") or from
# the arm64 defconfig of the patched tree ("arm64"): the assert entries on
# top, the host-dependent options off, olddefconfig.
configure() {  # <obj dir> a7s|arm64
  local o off=()
  mkdir -p "$1"
  case "$2" in
    a7s)   cp "$TOP/$DEFCONFIG_FILE" "$1/.config" ;;
    arm64) KOBJ=$1 kmake defconfig >/dev/null ;;
    *)     die "configure: no base '$2'" ;;
  esac
  apply_asserts "$1"
  for o in "${HOST_DEPENDENT_OPTIONS[@]}"; do off+=(-d "$o"); done
  "$SRC/scripts/config" --file "$1/.config" "${off[@]}"
  KOBJ=$1 kmake olddefconfig >/dev/null
}

# The settings of a defconfig file, and the comment above them.
defconfig_body() { awk '/^# CONFIG_[A-Za-z0-9_]+ is not set$/ || (!/^#/ && NF)' "$1"; }
defconfig_header() {
  awk '/^# CONFIG_[A-Za-z0-9_]+ is not set$/ || (!/^#/ && NF) { exit } { print }' "$1"
}

# config/a7s_defconfig must give the configuration that the arm64
# defconfig of the patched tree plus the assert entries give, and be in the
# minimal form savedefconfig writes: then it is that and nothing else. A
# new "arm64: defconfig" patch in the series fails here until the file is
# written again (stage savedefconfig).
check_defconfig() {
  local d="$WORK/obj-defconfig"
  rm -rf "$d"
  configure "$d" arm64
  if ! cmp -s "$d/.config" "$OBJ/.config"; then
    diff -u --label "arm64 defconfig + $ASSERT_FILE" --label "$DEFCONFIG_FILE" \
      "$d/.config" "$OBJ/.config" >&2 || true
    die "$DEFCONFIG_FILE is not the arm64 defconfig plus $ASSERT_FILE -- ./build.sh prepare savedefconfig writes the file it should be"
  fi
  rm -rf "$d"
  KOBJ=$OBJ kmake savedefconfig >/dev/null
  if ! diff -u --label "$DEFCONFIG_FILE" --label "savedefconfig" \
         <(defconfig_body "$TOP/$DEFCONFIG_FILE") "$OBJ/defconfig" >&2; then
    die "$DEFCONFIG_FILE is not in minimal form -- ./build.sh prepare savedefconfig writes it"
  fi
  rm -f "$OBJ/defconfig"
}

stage_config() {
  [ -f "$TOP/$DEFCONFIG_FILE" ] || die "no $DEFCONFIG_FILE"
  log "config: $DEFCONFIG_FILE + $ASSERT_FILE"
  configure "$OBJ" a7s
  check_defconfig
  # The fragment is kept in the work directory, so that the package stage
  # names the one this configuration was made with.
  rm -f "$WORK/config-fragment"
  if [ -n "${A7S_CONFIG_FRAGMENT:-}" ]; then
    [ -f "$A7S_CONFIG_FRAGMENT" ] || die "A7S_CONFIG_FRAGMENT: no file $A7S_CONFIG_FRAGMENT"
    log "config: + fragment $A7S_CONFIG_FRAGMENT"
    cp "$A7S_CONFIG_FRAGMENT" "$WORK/config-fragment"
    "$SRC/scripts/kconfig/merge_config.sh" -m -O "$OBJ" "$OBJ/.config" "$WORK/config-fragment" >/dev/null
    local o off=()
    for o in "${HOST_DEPENDENT_OPTIONS[@]}"; do off+=(-d "$o"); done
    "$SRC/scripts/config" --file "$OBJ/.config" "${off[@]}"
    kmake olddefconfig >/dev/null
    check_config_fragment "$WORK/config-fragment"
  fi
  check_asserts "$OBJ/.config" ${A7S_CONFIG_FRAGMENT:+"$WORK/config-fragment"}
  check_reproducible_config
}

# Write config/a7s_defconfig as it should be, to work/a7s_defconfig: the
# arm64 defconfig of the patched tree plus the assert entries, in minimal
# form, under the comment of the file in the repository.
stage_savedefconfig() {
  local d="$WORK/obj-defconfig"
  rm -rf "$d"
  configure "$d" arm64
  KOBJ=$d kmake savedefconfig >/dev/null
  { [ ! -f "$TOP/$DEFCONFIG_FILE" ] || defconfig_header "$TOP/$DEFCONFIG_FILE"
    cat "$d/defconfig"; } > "$WORK/a7s_defconfig"
  rm -rf "$d"
  log "wrote a7s_defconfig in the work directory: copy it to $DEFCONFIG_FILE"
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

# The tree for building modules outside the kernel tree, as
# /usr/src/kernels/<release>/ of kernel-a7s-devel: the kernel's own
# install-extmod-build, which also rebuilds the programs that modpost and
# the build need (fixdep, modpost, genksyms and others) for arm64 when the
# builder is not an arm64 host. The result is src/kernels/<release>/ in
# <dest>/devel-<release>.tar.gz.
package_devel() {  # <release> <destination directory>
  local rel=$1 root="$WORK/develroot" tree
  tree="$root/src/kernels/$rel"
  rm -rf "$root"
  kmake run-command KBUILD_RUN_COMMAND="\$(srctree)/scripts/package/install-extmod-build $tree" >/dev/null
  # The rebuild of the programs leaves an assembler file with the build path.
  find "$tree/scripts" -name '*.s' -delete
  cp "$OBJ/.config" "$tree/.config"
  check_devel_tree "$tree"
  # install-extmod-build keeps the modes of the source tree, which are those
  # of the kernel.org tarball (664/775) or less, depending on how the
  # container engine unpacked it. The modes here do not depend on it.
  tar -C "$root" --format=gnu --sort=name --mtime="@$SOURCE_DATE_EPOCH" \
    --owner=0 --group=0 --numeric-owner --mode=u+rwX,go=rX \
    -cf - src | gzip -n -9 > "$2/devel-$rel.tar.gz"
}

# Everything the board's make runs from scripts/ and tools/ must be an arm64
# program, not one of the builder; and no link may point out of the tree.
check_devel_tree() {  # <tree>
  local f n=0 bad=""
  while IFS= read -r -d '' f; do
    [ "$(head -c4 "$f")" = $'\177ELF' ] || continue
    n=$((n + 1))
    readelf -h "$f" | grep -q 'Machine:.*AArch64' || bad="$bad"$'\n'"  ${f#"$1/"}"
  done < <(find "$1" -type f \( -path '*/scripts/*' -o -path '*/tools/*' \) -print0 | sort -z)
  [ "$n" -gt 0 ] || die "devel: no program in scripts/ of the headers tree"
  [ -z "$bad" ] || die "devel: programs not built for arm64:$bad"
  bad=$(find "$1" -type l -lname '/*' -printf '  %P -> %l\n')
  [ -z "$bad" ] || die "devel: links to absolute paths:"$'\n'"$bad"
  for f in .config Module.symvers include/generated/utsrelease.h include/config/auto.conf \
           arch/arm64/include/generated scripts/mod/modpost; do
    [ -e "$1/$f" ] || die "devel: $f is missing in the headers tree"
  done
  log "devel: $n programs in scripts/ and tools/, all arm64"
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
  cp "$OBJ/System.map" "$OUT/System.map-$rel"
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
  package_devel "$rel" "$OUT"

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
    echo "patches.sha256=$(patches_sha256)"
    [ -z "$(checkout_commit)" ] || echo "commit=$(checkout_commit)"
    echo "patches=$(series_entries | wc -l)"
    echo "config=$DEFCONFIG_FILE"
    echo "config.sha256=$(sha256sum < "$TOP/$DEFCONFIG_FILE" | cut -d' ' -f1)"
    echo "config.assert.sha256=$(sha256sum < "$TOP/$ASSERT_FILE" | cut -d' ' -f1)"
    [ -z "$REVISION" ] || echo "revision=$REVISION"
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
  leak=$(grep -rlaF "$WORK/" "$OUT" "$WORK/modroot" "$WORK/develroot" "$OBJ/vmlinux" || true)
  [ -z "$leak" ] || die "build paths leak into: $leak"
  check_source_unchanged
  # The modules and the headers tree are in their tarballs now.
  rm -rf "$WORK/modroot" "$WORK/develroot"
  log "out: $(wc -l < "$OUT/SHA256SUMS") files, kernel $rel"
}

# --- release ----------------------------------------------------------------
# A release is made from a finished build (stages up to package) of a
# committed checkout, with A7S_KERNEL_REVISION from the tag. It writes
# out/release/: Image, the board's device tree, config, System.map, the
# modules, KERNEL-ID, the RPMs kernel-a7s, kernel-a7s-common and
# kernel-a7s-devel, the kernel.org tarball and its signature, and SHA256SUMS. Nothing in it is
# compiled again, and nothing in it is firmware.

# MODULE_LICENSE strings that are GPL-compatible (include/linux/license.h).
GPL_LICENSES='GPL|GPL v2|GPL and additional rights|Dual BSD/GPL|Dual MIT/GPL|Dual MPL/GPL'

manifest_get() { sed -n "s/^$1=//p" "$OUT/MANIFEST"; }
file_sha256() { sha256sum < "$1" | cut -d' ' -f1; }

# The RPM's release: r<n> is <n>; a test build t<n> is 0.t<n>, which sorts
# before release 1 of the same kernel version.
rpm_release() {
  case "$REVISION" in r*) echo "${REVISION#r}" ;; t*) echo "0.$REVISION" ;; esac
}

# out/ must be the build of this checkout as committed, with no switch
# that changes the output.
release_check_build() {
  [ -n "$REVISION" ] || die "release: set A7S_KERNEL_REVISION (r<n> or t<n>)"
  [ "$RC" = 0 ] || die "release: a release candidate is not released"
  [ -f "$OUT/MANIFEST" ] || die "release: no $OUT/MANIFEST -- run the build first"
  (cd "$OUT" && sha256sum -c --quiet SHA256SUMS) || die "release: $OUT does not match its SHA256SUMS"
  [ "$(manifest_get kernel.release)" = "$(kernel_release)" ] \
    || die "release: out/ holds $(manifest_get kernel.release), not $(kernel_release)"
  [ "$(manifest_get revision)" = "$REVISION" ] || die "release: out/ was built without revision $REVISION"
  [ -z "$(manifest_get config.fragment.sha256)" ] || die "release: a build with A7S_CONFIG_FRAGMENT is no release"
  [ "$(manifest_get config.sha256)" = "$(file_sha256 "$TOP/$DEFCONFIG_FILE")" ] \
    && [ "$(manifest_get config.assert.sha256)" = "$(file_sha256 "$TOP/$ASSERT_FILE")" ] \
    && [ "$(manifest_get series.sha256)" = "$(file_sha256 "$TOP/patches/series")" ] \
    || die "release: out/ was built from another config or series than this checkout"
  [ "$(manifest_get patches.sha256)" = "$(patches_sha256)" ] \
    || die "release: out/ was built from other patches than this checkout"
  [ "$(manifest_get source_date_epoch)" = "$(cat "$WORK/source-date-epoch")" ] \
    || die "release: out/ was built with another SOURCE_DATE_EPOCH than the tarball's"
  git -C "$TOP" -c safe.directory="$TOP" rev-parse -q --verify HEAD >/dev/null \
    || die "release: $TOP is not a git checkout"
  [ -z "$(git -C "$TOP" -c safe.directory="$TOP" status --porcelain)" ] \
    || die "release: the checkout has uncommitted changes; a release is built from a commit"
  [ "$(manifest_get commit)" = "$(checkout_commit)" ] \
    || die "release: out/ was built from commit '$(manifest_get commit)', this checkout is at $(checkout_commit)"
}

# The modules of the tarball, unpacked to <dir>: nothing but modules and
# depmod's files, each module with a GPL-compatible licence.
release_check_modules() {  # <dir> <release>
  local d=$1 rel=$2 bad n=0 ko lic
  tar -C "$d" -xzf "$OUT/modules-$rel.tar.gz"
  bad=$(cd "$d" && find . ! -type d ! -path "./lib/modules/$rel/*.ko" ! -path "./lib/modules/$rel/modules.*")
  [ -z "$bad" ] || die "release: the module tarball holds more than modules:"$'\n'"$bad"
  bad=""
  while IFS= read -r -d '' ko; do
    lic=$(modinfo -F license "$ko" | head -n1)
    printf '%s\n' "$lic" | grep -qxE "$GPL_LICENSES" || bad="$bad"$'\n'"  ${ko#"$d/"}: '$lic'"
    n=$((n + 1))
  done < <(find "$d" -name '*.ko' -print0 | sort -z)
  [ "$n" -gt 0 ] || die "release: no module in the tarball"
  [ -z "$bad" ] || die "release: modules without a GPL-compatible licence:$bad"
  log "release: $n modules, all GPL-compatible"
}

# kernel-a7s, kernel-a7s-common and kernel-a7s-devel from out/, by rpm/kernel-a7s.spec. Same
# input, same bytes: the build time is SOURCE_DATE_EPOCH, file times are
# clamped to it, the build host is fixed and the payload is compressed by
# one thread.
release_build_rpm() {  # <rpm top dir> <release>
  rm -rf "$1"
  rpmbuild -bb --quiet --target aarch64 \
    --define "_topdir $1" --define "_sourcedir $OUT" --define "_rpmdir $1/RPMS" \
    --define "_rpmfilename %%{NAME}-%%{VERSION}-%%{RELEASE}.%%{ARCH}.rpm" \
    --define "kver $2" --define "rpmver $(kernel_base)" --define "rpmrel $(rpm_release)" \
    --define "_buildhost $KBUILD_BUILD_HOST" \
    --define "source_date_epoch_from_changelog 0" \
    --define "use_source_date_epoch_as_buildtime 1" \
    --define "build_mtime_policy clamp_to_source_date_epoch" \
    --define "_binary_payload w19.zstdio" \
    "$TOP/$RPM_SPEC" >/dev/null || die "release: rpmbuild failed"
}

# The RPM must be this build: its kernel the Image, its modules those of
# the tarball (unpacked in <dir>), and no file outside the kernel's paths.
# kernel-a7s is installonly: every path in it carries the kernel release, or
# two versions installed side by side would conflict.
release_check_rpm() {  # <rpm> <dir> <release>
  local r=$1 d=$2 rel=$3 bad
  [ "$(rpm -qp --qf '%{VERSION}-%{RELEASE}.%{ARCH}' "$r")" = "$(kernel_base)-$(rpm_release).aarch64" ] \
    || die "release: $r has the wrong version or architecture"
  bad=$(rpm -qp --qf '[%{FILENAMES}\n]' "$r" | grep -vE \
    "^(/usr/lib/modules/$rel(/.*)?|/boot/(vmlinuz|config|initramfs|dtb)-$rel(\\.img)?)$" || true)
  [ -z "$bad" ] || die "release: $r holds files outside the paths of its kernel release (installonly):"$'\n'"$bad"
  rpm -qp --requires "$r" | grep -qxF "kernel-a7s-common >= $(kernel_base)-$(rpm_release)" \
    || die "release: $r does not require kernel-a7s-common"
  ! rpm -qp --qf '[%{FILENAMES}\n]' "$r" | grep -qxF "/usr/lib/modules/$rel/build" \
    || die "release: $r holds the link to the headers, which belongs to kernel-a7s-devel"
  rpm -qp --qf '[%{FILEDIGESTS} %{FILENAMES}\n]' "$r" \
    | grep -qxF "$(file_sha256 "$OUT/Image") /usr/lib/modules/$rel/vmlinuz" \
    || die "release: the kernel in $r is not out/Image"
  cmp -s <(rpm -qp --qf '[%{FILEDIGESTS} %{FILENAMES}\n]' "$r" | grep '\.ko$' | sed 's# /usr/# /#' | sort -k2) \
         <(cd "$d" && find . -name '*.ko' -print0 | xargs -0 sha256sum | sed 's#  \./# /#' | sort -k2) \
    || die "release: the modules in $r are not those of the module tarball"
}

# kernel-a7s-common: noarch, these two files and no other, the contents of
# the spec, and not installonly.
release_check_common() {  # <rpm>
  local r=$1 want got
  [ "$(rpm -qp --qf '%{VERSION}-%{RELEASE}.%{ARCH}' "$r")" = "$(kernel_base)-$(rpm_release).noarch" ] \
    || die "release: $r has the wrong version or architecture"
  want=$'/usr/lib/kernel/install.d/25-a7s-dtb-to-esp.install\n/usr/share/dnf5/libdnf.conf.d/80-kernel-a7s.conf'
  got=$(rpm -qp --qf '[%{FILENAMES}\n]' "$r" | sort)
  [ "$got" = "$want" ] || die "release: $r does not hold exactly its two files:"$'\n'"$got"
  ! rpm -qp --provides "$r" | grep -q installonlypkg \
    || die "release: $r is installonly, which its files must not be"
  [ "$(rpm -qp --qf '[%{FILEMODES:perms} %{FILENAMES}\n]' "$r" | sed -n 's# /usr/lib/kernel/.*##p')" = "-rwxr-xr-x" ] \
    || die "release: the kernel-install plugin in $r is not executable"
}

# kernel-a7s-devel must be this build too: the headers tree of the tarball
# (unpacked in <dir>, checked as when it was made) with nothing else, the
# link to it, and a Requires on the kernel it belongs to.
release_check_devel() {  # <rpm> <dir> <release>
  local r=$1 d=$2 rel=$3 bad
  tar -C "$d" -xzf "$OUT/devel-$rel.tar.gz"
  check_devel_tree "$d/src/kernels/$rel"
  [ -z "$(grep -rlaF "$WORK/" "$d" || true)" ] || die "release: build paths leak into the headers tree"
  [ "$(rpm -qp --qf '%{VERSION}-%{RELEASE}.%{ARCH}' "$r")" = "$(kernel_base)-$(rpm_release).aarch64" ] \
    || die "release: $r has the wrong version or architecture"
  rpm -qp --requires "$r" | grep -qxF "kernel-a7s = $(kernel_base)-$(rpm_release)" \
    || die "release: $r does not require kernel-a7s of the same version and release"
  bad=$(rpm -qp --qf '[%{FILENAMES}\n]' "$r" | grep -vE \
    "^(/usr/src/kernels/$rel(/.*)?|/usr/lib/modules/$rel/build)$" || true)
  [ -z "$bad" ] || die "release: $r holds files outside the headers tree:"$'\n'"$bad"
  [ "$(rpm -qp --qf '[%{FILENAMES} %{FILELINKTOS}\n]' "$r" | sed -n "s#^/usr/lib/modules/$rel/build ##p")" = "/usr/src/kernels/$rel" ] \
    || die "release: $r does not link /usr/lib/modules/$rel/build to /usr/src/kernels/$rel"
  cmp -s <(rpm -qp --qf '[%{FILEDIGESTS} %{FILENAMES}\n]' "$r" | grep -E '^[0-9a-f]{64} ' | sed 's# /usr/# /#' | sort -k2) \
         <(cd "$d" && find src -type f -print0 | xargs -0 sha256sum | sed 's#  src/# /src/#' | sort -k2) \
    || die "release: the files in $r are not those of the headers tarball"
}

# What the release is: the MANIFEST of the build, the revision, the RPMs and
# the sha256 of the loose kernel files.
release_kernel_id() {  # <dest> <release>
  local f
  cat "$OUT/MANIFEST"
  echo "rpm=$(cd "$1" && ls kernel-a7s-[0-9]*.rpm)"
  echo "rpm.common=$(cd "$1" && ls kernel-a7s-common-*.rpm)"
  echo "rpm.devel=$(cd "$1" && ls kernel-a7s-devel-*.rpm)"
  for f in Image "${BOARD_DTB##*/}" config System.map; do
    echo "sha256_$f=$(file_sha256 "$1/$f")"
  done
}

stage_release() {
  release_check_build
  set_build_time
  local rel dest stage rpm common devel
  rel=$(kernel_release)
  dest="$OUT/release"
  stage="$WORK/release-stage"
  rm -rf "$dest" "$stage"
  mkdir -p "$dest" "$stage/modules" "$stage/devel"
  release_check_modules "$stage/modules" "$rel"
  release_build_rpm "$stage/rpmbuild" "$rel"
  rpm="$stage/rpmbuild/RPMS/kernel-a7s-$(kernel_base)-$(rpm_release).aarch64.rpm"
  [ -f "$rpm" ] || die "release: rpmbuild made no ${rpm##*/}"
  release_check_rpm "$rpm" "$stage/modules" "$rel"
  common="$stage/rpmbuild/RPMS/kernel-a7s-common-$(kernel_base)-$(rpm_release).noarch.rpm"
  [ -f "$common" ] || die "release: rpmbuild made no ${common##*/}"
  release_check_common "$common"
  devel="$stage/rpmbuild/RPMS/kernel-a7s-devel-$(kernel_base)-$(rpm_release).aarch64.rpm"
  [ -f "$devel" ] || die "release: rpmbuild made no ${devel##*/}"
  release_check_devel "$devel" "$stage/devel" "$rel"

  cp "$OUT/Image" "$rpm" "$common" "$devel" "$dest/"
  cp "$OUT/config-$rel" "$dest/config"
  cp "$OUT/System.map-$rel" "$dest/System.map"
  cp "$OUT/modules-$rel.tar.gz" "$dest/a7s-linux-mainline-$rel-modules.tar.gz"
  tar -xzOf "$OUT/dtbs-$rel.tar.gz" "$BOARD_DTB" > "$dest/${BOARD_DTB##*/}"
  # The corresponding source: the kernel.org tarball unchanged, with its
  # signature. The patches, config and scripts are the tag's source archive.
  echo "$KERNEL_SHA256  $DL/$TARBALL" | sha256sum -c --quiet - || die "release: $TARBALL does not match the pinned sha256"
  cp "$DL/$TARBALL" "$DL/$SIGNATURE" "$dest/"
  release_kernel_id "$dest" "$rel" > "$dest/KERNEL-ID"
  (cd "$dest" && find . -type f ! -name SHA256SUMS -printf '%P\n' | sort | xargs sha256sum > SHA256SUMS)
  rm -rf "$stage"
  log "release: $(wc -l < "$dest/SHA256SUMS") files in $dest"
}

# Sourced: the settings and functions only, no stage.
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0

stages=("$@")
[ ${#stages[@]} -gt 0 ] || stages=(fetch verify prepare config build package)
preflight "${stages[@]}"
for s in "${stages[@]}"; do
  case "$s" in
    version|tag-version|fetch|verify|prepare|config|savedefconfig|build|package|release)
      "stage_${s//-/_}" ;;
    *) die "unknown stage: $s" ;;
  esac
done
