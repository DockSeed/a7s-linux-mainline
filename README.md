# a7s-linux-mainline

Linux kernel patches for the **Radxa Cubie A7S** (Allwinner A733), on top
of mainline Linux 7.3, and a script that builds the kernel from them.

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
| `Image` | the kernel |
| `dtbs-<release>.tar.gz` | device trees, incl. `allwinner/sun60i-a733-cubie-a7s.dtb` |
| `modules-<release>.tar.gz` | `lib/modules/<release>/` |
| `config-<release>` | kernel config |
| `MANIFEST` | inputs: kernel, tarball sha256, series sha256, toolchain |
| `SHA256SUMS` | checksums of the files above |

`<release>` is `7.3.0-a7s` by default.

## Install

You need a working system on the board and the boot chain from
[a733-bootchain](https://github.com/DockSeed/a733-bootchain). Keep your
current kernel: install this one next to it.

1. Copy `Image` to `/boot/vmlinuz-7.3.0-a7s` and unpack the device trees:
   `sudo mkdir -p /boot/dtbs/7.3.0-a7s` and
   `sudo tar -C /boot/dtbs/7.3.0-a7s -xzf dtbs-7.3.0-a7s.tar.gz`.
2. Unpack the modules. On a merged-/usr system:
   `sudo tar -C /usr -xzf modules-7.3.0-a7s.tar.gz`. Do not unpack into
   `/`: the tarball's `lib/` would replace the `/lib` symlink.
3. Add an entry to `/boot/extlinux/extlinux.conf` and make it the
   default. Keep your old entry:

   ```
   default mainline
   label mainline
       kernel /boot/vmlinuz-7.3.0-a7s
       fdt /boot/dtbs/7.3.0-a7s/allwinner/sun60i-a733-cubie-a7s.dtb
       append root=PARTUUID=<your root> rootwait rw console=ttyS0,115200
   ```

The defconfig builds the NVMe driver, the PCIe PHY and the watchdog as
modules. With an initramfs that is fine. Without one, for example with
the root file system on NVMe, build them in:

```
printf 'CONFIG_BLK_DEV_NVME=y\nCONFIG_PHY_SUN60I_A733_PCIE_COMBO=y\nCONFIG_SUNXI_WATCHDOG=y\n' > my.config
A7S_CONFIG_FRAGMENT=my.config ./build.sh
```

The watchdog matters: the boot chain starts it, and the board resets
about 16 s after boot unless Linux takes it over.

**Going back:** set `default` to your old entry again. If the new kernel
does not come up at all, the boot chain's safe mode helps: after three
boots that were not marked good, it boots
`/boot/extlinux/extlinux-fallback.conf` with your old kernel, if you put
one there. Marking a boot good is the system's job; the a733-bootchain
README explains how. To remove the kernel, delete its entry, the files
in `/boot` and `/usr/lib/modules/7.3.0-a7s`.

## Reproducible

The builder image is pinned: base image by digest, packages from a fixed
Debian snapshot (`build-env/packages-<arch>.lock`). Two builds of the same
tree give the same `SHA256SUMS`, checked twice on each architecture.
x86_64 (cross compiler) and arm64 (native compiler) hosts give different
results: the compiler name ends up in the kernel config.

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
| `A7S_LOCALVERSION` | default `-a7s` |
| `A7S_KERNEL_MIRROR` | kernel.org mirror, verified the same way |
| `JOBS` | parallel jobs, default all CPUs |
| `SOURCE_DATE_EPOCH` | default: mtime of the tarball's `Makefile` |
| `A7S_W1` | `1` builds with `W=1`, warnings go to `work/warnings.txt` |

`A7S_CONFIG_FRAGMENT`, `A7S_LOCALVERSION` and `SOURCE_DATE_EPOCH` change
the output.

## Configuration

The build uses the arm64 `defconfig` of the patched tree. A defconfig
patch in the series enables the A7S drivers. Put your own options in
`A7S_CONFIG_FRAGMENT`; the build stops if one does not take. Apart from
that, the build only switches off options that make the output depend on
the host (see `stage_config` in `scripts/build.sh`).

## Checking the patches

```
./build.sh fetch verify
./build.sh shell sh -c 'python3 scripts/patch-check.py --repo . \
  --tarball /work/dl/linux-$(scripts/build.sh version).tar.xz --workdir /work/pc'
```

Applies the series with `git am`, checks `patches/series`, the tags and
the format from [CONTRIBUTING.md](CONTRIBUTING.md), and runs
`checkpatch.pl --strict` on our patches. GitHub Actions runs this and a
full build on pull requests and pushes to `main`. It uploads nothing.

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

- WLAN and Bluetooth: the module is powered, but there is no driver.
- Video decoding, 2D accelerator (G2D), deinterlacer, camera input:
  device tree only, no driver.
- The GPU needs firmware that is not in linux-firmware yet
  (`rogue_36.56.104.183_v1.fw`).
- Suspend: any system sleep resets the board, so the series switches
  `CONFIG_SUSPEND` off.

Our patches are written with an AI assistant. Patches by other authors
are taken as posted or as applied upstream. No kernel developer has
reviewed our code yet.

## License

GPL-2.0-only unless a file says otherwise ([LICENSE](LICENSE)).
Third-party parts: [NOTICE](NOTICE).
