# a7s-linux-mainline

Linux kernel patches for the **Radxa Cubie A7S** (Allwinner A733), on top
of Linux 7.3.3, and a script that builds the kernel from them.

**What it is:** a kernel you build yourself and install on a system that
already runs on the board. It goes together with the boot chain from
[a733-bootchain](https://github.com/DockSeed/a733-bootchain), which it is
tested with.

**What it is not:** not a distribution, not a disk image, no binaries,
no firmware and no boot loader. Not mainline Linux, and not a submission:
the patches are not posted upstream in this form. Only the Cubie A7S is
tested. This project is not affiliated with Allwinner or Radxa.

## Build

Needs Linux on x86_64 or arm64, bash, podman or docker, network access
and about 6 GB of disk. With rootless podman no root is needed.

```
./build.sh
```

The first run builds the builder image from `build-env/` (about a
minute). Then the script downloads the kernel.org tarball, checks its
sha256 and signature, applies `patches/series` and builds. Measured: 43
min on a 4-core i5-7500T, 69 min on the Cubie A7S itself. Compiler
messages are kept in `work/build.stderr`.

On SELinux systems the build container runs with
`--security-opt label=disable`, so your directories keep their labels.

Rootless podman needs a user session bus (`dbus-user-session` on Debian).
Log in again after installing it, otherwise `podman build` fails with
`sd-bus call: Permission denied`.

## Output

`out/` holds:

| File | Contents |
|---|---|
| `a7s-linux-mainline-<release>.tar.gz` | the kernel: `Image`, `dtbs/` with the device trees, incl. `allwinner/sun60i-a733-cubie-a7s.dtb`, `lib/modules/<release>/`, `config`, `System.map` and [INSTALL.md](INSTALL.md) with the release filled in |
| `a7s-linux-mainline-<release>-headers.tar.gz` | `lib/modules/<release>/build/`: headers, configuration, `Module.symvers` and build tools for modules outside the kernel tree; the tools are built for arm64 |
| `MANIFEST` | inputs: kernel, tarball sha256, series, patches and config sha256, commit, toolchain |
| `SHA256SUMS` | checksums of the files above |

Both tarballs have the one top directory `a7s-linux-mainline-<release>/`.
`<release>` is `7.3.3-a7s` by default, `7.3.3-a7s-t1` for the test build
`v7.3.3-T1`. Releases also come ready built, see [Releases](#releases).

## Install

You need a working system on the board and the boot chain from
[a733-bootchain](https://github.com/DockSeed/a733-bootchain). The kernel
is meant for a distribution that boots the board with U-Boot and extlinux:
[INSTALL.md](INSTALL.md) says how to install it next to your current
kernel, and how to go back. Its steps are generic and not tried out on
every distribution. The tarball holds the same guide with the release
filled in.

The defconfig builds the NVMe driver, the PCIe PHY and the watchdog as
modules. With an initramfs that is fine. Without one, for example with
the root file system on NVMe, build them in:

```
printf 'CONFIG_BLK_DEV_NVME=y\nCONFIG_PHY_SUN60I_A733_PCIE_COMBO=y\nCONFIG_SUNXI_WATCHDOG=y\n' > my.config
A7S_CONFIG_FRAGMENT=my.config ./build.sh
```

## Reproducible

The builder image is pinned: base image by digest, packages from a fixed
Debian snapshot (`build-env/packages-<arch>.lock`). The build time comes
from the kernel.org tarball, and the tarballs are written with sorted
names, fixed times, owners and modes, so that two builds of the same tree
give the same `SHA256SUMS`; compare them to check. x86_64 (cross compiler)
and arm64 (native compiler) hosts give different results: the compiler
name ends up in the kernel config.

## Clean up

```
./build.sh clean
```

Removes `./work`, the builder images and the Debian base image if the
build pulled it. Keeps `out/` and leaves everything else in podman or
docker alone. Use the same `A7S_WORK` as for the build.

## Options

```
./build.sh --help
./build.sh version          # pinned kernel version
./build.sh fetch verify     # download and check only
./build.sh prepare config   # patch and configure, no build
./build.sh shell            # shell in the builder
```

| Variable | Meaning |
|---|---|
| `A7S_ENGINE` | `podman` or `docker`, default podman if installed |
| `A7S_WORK`, `A7S_OUT` | work and output directories, relative to the repository |
| `A7S_CONFIG_FRAGMENT` | your own config fragment, merged after defconfig |
| `A7S_LOCALVERSION` | default `-a7s`; not together with `A7S_KERNEL_REVISION` |
| `A7S_KERNEL_REVISION` | `r<n>` or `t<n>`: build the release `R<n>` or test build `T<n>` (see [Releases](#releases)) |
| `A7S_KERNEL_MIRROR` | kernel.org mirror, verified the same way |
| `JOBS` | parallel jobs, default all CPUs |
| `SOURCE_DATE_EPOCH` | default: mtime of the tarball's `Makefile` |
| `A7S_W1` | `1` builds with `W=1`, warnings go to `work/warnings.txt` |

`A7S_CONFIG_FRAGMENT`, `A7S_LOCALVERSION` and `SOURCE_DATE_EPOCH` change
the output.

## Configuration

The kernel is configured for a general-purpose distribution on the board.
[config/a7s_defconfig](config/a7s_defconfig) is the arm64 `defconfig` of
the patched tree (the defconfig patches in the series enable the A7S
drivers) plus what such a system needs from the kernel, among it SELinux
and AppArmor, nftables, zram swap and pressure stall information. Of
SELinux and AppArmor only one starts: SELinux, in the kernel's own default
order, unless `lsm=` on the command line says otherwise
([INSTALL.md](INSTALL.md)). [config/kernel-config.assert](config/kernel-config.assert)
lists these additions and what the board needs, each block with its reason.

The config stage checks that the file is exactly that defconfig plus the
list, in the minimal form of `make savedefconfig`, and that every entry of
the list is in the final configuration. After a change of the list or of a
defconfig patch, write the file again:

```
./build.sh prepare savedefconfig
cp work/a7s_defconfig config/a7s_defconfig
```

Put your own options in `A7S_CONFIG_FRAGMENT`; the build stops if one does
not take, and the fragment decides for the symbols it names. Apart from
that, the build only switches off options that make the output depend on
the host (see `stage_config` in `scripts/build.sh`).

## Releases

A release is named `v<version>-R<n>` (`v7.3.3-R1`), a test build
`v<version>-T<n>`; `<version>` is the kernel version as `uname -r` begins.
GitHub Actions ([release.yml](.github/workflows/release.yml)) builds the
tagged commit with `./build.sh` and `./build.sh release` in the same pinned
builder container, on an x86_64 runner, and creates a draft release whose
text is the tag's section in [CHANGELOG.md](CHANGELOG.md). The maintainer
publishes it by hand; a test build is marked as a pre-release.

New releases follow new mainline kernels and fixes to the series as they
become ready. They come without a fixed schedule, and offering them is not
a promise to do so forever.

Attached to a release:

| File | What it is |
|---|---|
| `a7s-linux-mainline-<release>.tar.gz` | the kernel for a distribution that boots the board with U-Boot and extlinux, as in `out/` (see [Output](#output)); [INSTALL.md](INSTALL.md) in it says how to install it |
| `a7s-linux-mainline-<release>-headers.tar.gz` | the headers tree of the same build, as in `out/`, for modules outside the kernel tree, also with DKMS |
| `Image`, `sun60i-a733-cubie-a7s.dtb`, `config`, `System.map` | the same files as in the kernel tarball |
| `KERNEL-ID` | `MANIFEST` of the build, the revision, the names of the two tarballs and the sha256 of the four loose kernel files |
| `linux-<kernel>.tar.xz`, `.tar.sign` | the unchanged kernel tarball from kernel.org and its signature |
| `SHA256SUMS` | the sha256 of every file above |

No firmware is part of a release, and `./build.sh release` stops if the
kernel tarball holds anything but the kernel, its device trees, modules and
the files named above, if a module's licence is not GPL-compatible, if the
headers tarball holds anything but the headers tree or a build tool in it
is not an arm64 program, or if `out/` was built from other patches or
another commit than the checkout. The kernel.org tarball and the source
archive of the tag, which GitHub adds to every release, are the
corresponding source (GPL-2.0).

To check a release: `sha256sum -c SHA256SUMS`, then build the tagged
commit on x86_64 with the revision of the tag (`t1` for `v7.3.3-T1`) and
compare:

```
A7S_KERNEL_REVISION=t1 ./build.sh
A7S_KERNEL_REVISION=t1 ./build.sh release
```

`out/release/` should then hold the same files: the build time is the
kernel.org tarball's.

## Checking the patches

```
./build.sh fetch verify
./build.sh shell sh -c 'python3 scripts/patch-check.py --repo . \
  --tarball /work/dl/linux-$(scripts/build.sh version).tar.xz --workdir /work/pc'
```

Applies the series with `git am`, checks `patches/series`, the tags and
the format from [CONTRIBUTING.md](CONTRIBUTING.md), and runs
`checkpatch.pl --strict` on our patches. Each upstream commit our
patches name (`Fixes:`, `commit <id> ("<subject>")`) must exist in
torvalds/linux on git.kernel.org with that subject; this needs network
access. GitHub Actions runs this and a full build on pull requests and
pushes to `main`. It uploads nothing.

## Signing keys

`keys/` holds the kernel.org keys `build.sh` accepts: the stable release
key `647F28654894E3BD457199BE38DBBDC86092693E` and Linus Torvalds' key
`ABAF11C65A2970B130ABE3C479BE3E4300411886` (for release candidates).
Compare them with <https://www.kernel.org/signature.html>.

## Status

Works and is tested on the board: pin control, clocks, power domains,
PMIC, SD and eMMC, Ethernet, USB 2 and 3, PCIe and NVMe, DMA, IOMMU,
thermal, cpufreq and CPU idle, display and DisplayPort over USB-C,
DisplayPort audio, the GPU. `patches/series` lists each series with
author and upstream state; each of our patches says how it was tested.

With the default governor (schedutil) the CPU does not go below the
fastest step that runs at the lowest voltage, also when idle. Which step
that is depends on the chip's speed bin. The lower steps save nothing,
so the kernel skips them.

Not supported yet:

- WLAN: the AIC8800 WLAN driver (`aic_load_fw`, `aic8800_fdrv`) and its
  firmware are not part of this kernel or of a release. Its Bluetooth
  runs on `btusb` (`CONFIG_BT_HCIBTUSB`) from this kernel.
- Video decoding, 2D accelerator (G2D), deinterlacer, camera input:
  device tree only, no driver.
- The GPU needs firmware that is not in linux-firmware yet
  (`rogue_36.56.104.183_v1.fw`).
- Suspend: it resets the board, so the configuration switches
  `CONFIG_SUSPEND` off.

Our patches are written with an AI assistant. Patches by other authors
are taken as posted or as applied upstream. No kernel developer has
reviewed our code yet.

## License

GPL-2.0-only unless a file says otherwise ([LICENSE](LICENSE)).
Third-party parts: [NOTICE](NOTICE).
