# Installing the kernel

For a system on the Radxa Cubie A7S, of any distribution, that boots with
U-Boot and extlinux, as with the boot chain from
[a733-bootchain](https://github.com/DockSeed/a733-bootchain). Keep your
current kernel and its entry: install this one next to it.

`<release>` is the kernel release, as `uname -r` will show it: the name of
the directory in `lib/modules/`. Unpack the tarball as a normal user and run
the commands as root in the directory it made,
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

   `/lib/modules` is the right place with and without a merged `/usr`. Do
   not unpack the tarball into `/`: its `lib/` would replace the `/lib`
   symlink.

3. An initramfs, made with your distribution's tool for this release, for
   example `dracut --kver <release>`, `update-initramfs -c -k <release>` or
   `mkinitcpio -k <release> -g /boot/initramfs-<release>.img`. It is needed
   for a root file system on NVMe: the NVMe driver, the PCIe PHY and the
   watchdog are modules. The drivers for SD and eMMC and ext4 are built in,
   so a root file system there boots without one.

4. An entry in `/boot/extlinux/extlinux.conf`, with the initramfs that step
   3 wrote and your root file system:

   ```
   label a7s-<release>
       kernel /boot/vmlinuz-<release>
       initrd /boot/initramfs-<release>.img
       fdt /boot/dtbs/<release>/allwinner/sun60i-a733-cubie-a7s.dtb
       append root=PARTUUID=<your root> rootwait rw console=ttyS0,115200
   ```

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
left to your distribution's tools. U-Boot then takes the device tree from
the EFI system partition: copy `dtbs/.` to `dtb/` on it.

## Modules outside the kernel tree

`a7s-linux-mainline-<release>-headers.tar.gz` holds the headers, the
configuration, `Module.symvers` and the build tools of the same build, as
`lib/modules/<release>/build/`. The tools are arm64 programs: build on the
board. Unpack it in the same place as the kernel tarball and copy the tree:

```
cp -r lib/modules/<release>/build /lib/modules/<release>/
```

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
