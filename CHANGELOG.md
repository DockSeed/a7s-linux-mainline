<!--
SPDX-License-Identifier: GPL-2.0-only
-->
# Changelog

Notable changes, one section per release. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

A tag is named `v<kernel version>-T<n>` for a test build or
`v<kernel version>-R<n>` for a release, for example `v7.3.0-R1`: the
version of the mainline kernel the recipe builds, as `uname -r` begins
(7.3 is `7.3.0`), a letter and a counter that starts again at 1 with each
new kernel version. Pushing such a tag builds it; the text of the draft
release is the section below with the same name.

## [Unreleased]

Nothing yet.

## [7.3.0-R1] - 2026-11-06

First release: the recipe of the test build 7.3.0-T2 with the fixes below;
the sections of T2 and T1 list what it contains.

### Fixed

- `rpmbuild` warned "File listed twice" for depmod's files (`modules.dep`,
  `modules.alias`, ...) in `kernel-a7s`: the spec removed them with a brace
  expansion, which `/bin/sh` of the builder (dash) does not know, so they
  stayed in the build root. They are removed now and listed once, as
  `%ghost`. The contents of the package do not change.
- The README and the release text said that dnf installs `kernel-a7s-common`
  with `kernel-a7s`. That holds only with a package repository; with
  downloaded files both must be named. The README now says how to install
  them and that the unsigned packages need `--nosignature` with `rpm`.

## [7.3.0-T2] - 2026-11-06

Test build.

### Fixed

- A second `kernel-a7s` could not be installed beside the first once the
  kernel-install plugin or the dnf configuration differed between them
  (file conflict): both now live in the new RPM `kernel-a7s-common`, which is
  updated and not installed beside an older one, and `kernel-a7s` holds only
  paths with the kernel release in their name. `./build.sh release` checks that.

## [7.3.0-T1] - 2026-11-05

Test build.

### Added

- Releases: a tag builds the kernel on GitHub Actions and attaches it to a
  draft release, as loose files and as the RPM `kernel-a7s` for Fedora
  (README.md, "Releases").
- The RPM `kernel-a7s-devel` with the headers, configuration,
  `Module.symvers` and build tools (built for arm64) of the kernel, in
  `/usr/src/kernels/<release>/`. With it, modules outside the kernel tree
  can be built on the board, also with DKMS.
- `config/a7s_defconfig`: the configuration of the kernel, the arm64
  defconfig of the patched tree plus what Fedora needs (SELinux as the
  default LSM, nftables, zram, pressure stall information and others),
  with the reasons in `config/kernel-config.assert`.
- `./build.sh savedefconfig` writes `config/a7s_defconfig` again, and
  `./build.sh release` makes the files of a release.

### Changed

- The build uses `config/a7s_defconfig` instead of the arm64 defconfig. The
  config stage stops when the file is not that defconfig plus the assert
  list, or when an entry of the list did not take.
- `out/` also holds `System.map-<release>` and `devel-<release>.tar.gz`, and
  `MANIFEST` names the configuration, the patches and the commit by their
  sha256 or id. `./build.sh release` stops if they are not those of the
  checkout.
- The builder image has `rpm` for `rpmbuild`.
