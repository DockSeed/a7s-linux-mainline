# Installing the kernel

For a distribution on the Radxa Cubie A7S that boots the board with U-Boot
and extlinux, as with the boot chain from
[a733-bootchain](https://github.com/DockSeed/a733-bootchain). The steps are
generic: they use no tool of one distribution beyond its initramfs
generator, and they are not tried out on every distribution. Keep your
current kernel and its entry: install this one next to it.

This is the kernel release `<release>`; `uname -r` shows it once the kernel
runs, and it names the directory in `lib/modules/`. Unpack the tarball as a
normal user and run the commands as root in the directory it made,
`a7s-linux-mainline-<release>/`.

1. The kernel, its configuration, symbol table and device trees:

   ```
   install -m 0644 Image /boot/vmlinuz-<release>
   install -m 0644 config /boot/config-<release>
   install -m 0644 System.map /boot/System.map-<release>
   mkdir -p /boot/dtbs/<release>
   cp -r dtbs/. /boot/dtbs/<release>/
   ```

2. The modules:

   ```
   cp -r lib/modules/<release> /lib/modules/
   depmod <release>
   ```

   If `/lib/modules/<release>` exists already, from an earlier try of the
   same release, remove it first (`rm -rf /lib/modules/<release>`, after
   checking the name): `cp -r` would otherwise put the new copy inside the
   old one.

   `/lib/modules` is the right place with and without a merged `/usr`. Do
   not unpack the tarball into `/`: its `lib/` would replace the `/lib`
   symlink.

3. An initramfs, made with your distribution's tool for this release.
   Note the file it writes, for the `initrd` line in step 4:

   | Tool | Command | File |
   |---|---|---|
   | dracut | `dracut /boot/initramfs-<release>.img <release>` | `/boot/initramfs-<release>.img` |
   | initramfs-tools | `update-initramfs -c -k <release>` | `/boot/initrd.img-<release>` |
   | mkinitcpio | `mkinitcpio -k <release> -g /boot/initramfs-<release>.img` | `/boot/initramfs-<release>.img` |

   A system that so far booted without an initramfs may not have the tool
   installed; install it first (on Debian: `apt update`, then
   `apt install initramfs-tools`).

   It is needed for a root file system on NVMe: the NVMe driver, the PCIe
   PHY and the watchdog are modules. It is also needed for a root file
   system on btrfs, which is a module too; XFS and F2FS are not built at
   all, so a root file system on them does not boot with this kernel. The
   drivers for SD and eMMC and ext4 are built in, so an ext4 root file
   system there boots without an initramfs.

4. An entry in `/boot/extlinux/extlinux.conf`, with your root file system
   and, in the `initrd` line, the file step 3 wrote (here dracut's or
   mkinitcpio's; with initramfs-tools `/boot/initrd.img-<release>`):

   ```
   label a7s-<release>
       kernel /boot/vmlinuz-<release>
       initrd /boot/initramfs-<release>.img
       fdt /boot/dtbs/<release>/allwinner/sun60i-a733-cubie-a7s.dtb
       append root=PARTUUID=<your root> rootwait rw console=ttyS0,115200
   ```

   Of SELinux and AppArmor, both built, only one starts: SELinux unless the
   command line says otherwise. Add the one your distribution uses to
   `append`, for example:

   ```
   append root=PARTUUID=<your root> rootwait rw console=ttyS0,115200 lsm=apparmor
   append root=PARTUUID=<your root> rootwait rw console=ttyS0,115200 lsm=selinux
   ```

   The first for Debian, Ubuntu and others with AppArmor, the second for
   Fedora and its relatives. `lsm=` replaces the kernel's LSM order; this
   kernel builds no other LSM that would need a place in it.

   The paths are those on the partition that holds `extlinux.conf`: with a
   separate `/boot` partition, leave out `/boot`. Without an initramfs, leave
   out the `initrd` line. Make the entry the default with
   `default a7s-<release>`. If a tool of your distribution writes
   `extlinux.conf` itself, it may overwrite the entry: add it where that tool
   takes its entries from.

The watchdog matters: the boot chain starts it, and the board resets about
16 s after boot unless Linux takes it over (module `sunxi_wdt`, loaded from
the initramfs or the root file system).

Booting through EFI instead (grub or systemd-boot, started by U-Boot) is
left to your distribution's tools. U-Boot then passes on a device tree it
loaded itself: copy the one from `dtbs/` to where your U-Boot build looks
for it.

## Modules outside the kernel tree

`a7s-linux-mainline-<release>-headers.tar.gz` holds the headers, the
configuration, `Module.symvers` and the build tools of the same build, as
`lib/modules/<release>/build/`. The tools are arm64 programs: build on the
board. Unpack it in the same place as the kernel tarball and copy the tree:

```
cp -r lib/modules/<release>/build /lib/modules/<release>/
```

As in step 2, remove an existing `/lib/modules/<release>/build` first, or
the new copy lands inside it.

`make -C /lib/modules/<release>/build M=$PWD` and DKMS find it there.

## Going back

Set `default` to your old entry again. If the new kernel does not come up
at all, the boot chain's safe mode helps: after three boots that were not
marked good, it boots `/boot/extlinux/extlinux-fallback.conf` with your old
kernel, if you put one there. Marking a boot good is the system's job; the
a733-bootchain README explains how.

To remove the kernel, delete its entry, `/boot/vmlinuz-<release>`,
`/boot/config-<release>`, `/boot/System.map-<release>`,
`/boot/dtbs/<release>`, its initramfs and `/lib/modules/<release>`.
