# SPDX-License-Identifier: GPL-2.0-only
#
# The kernel of a7s-linux-mainline as an RPM for Fedora: Image, device trees
# and modules from out/ of `./build.sh`, laid out as Fedora's kernel packages
# lay them out (/usr/lib/modules/<uname -r>/) and installed into /boot by
# kernel-install. Nothing is compiled here. `./build.sh release` builds it and
# defines kver (the kernel release), rpmver and rpmrel. The subpackage devel
# holds what builds modules outside the kernel tree, as Fedora's kernel-devel.

%global debug_package %{nil}
%global __os_install_post %{nil}
%global _build_id_links none

Name:           kernel-a7s
Version:        %{rpmver}
Release:        %{rpmrel}
Summary:        Linux kernel for the Radxa Cubie A7S
License:        GPL-2.0-only
URL:            https://github.com/DockSeed/a7s-linux-mainline
ExclusiveArch:  aarch64
AutoReqProv:    no
Source0:        Image
Source1:        config-%{kver}
Source2:        dtbs-%{kver}.tar.gz
Source3:        modules-%{kver}.tar.gz
Source4:        devel-%{kver}.tar.gz

# Stands in for Fedora's kernel packages, which do not boot this board.
# No kernel-uname-r: Fedora's is version-release.arch, which this kernel's
# uname -r is not.
Provides:       kernel = %{version}-%{release}
Provides:       kernel-core = %{version}-%{release}
Provides:       kernel-modules = %{version}-%{release}
Provides:       kernel-modules-core = %{version}-%{release}
Provides:       installonlypkg(kernel)
Requires(pre):  coreutils systemd
Requires(posttrans): systemd-udev dracut kmod

%description
Mainline Linux with the patch series of a7s-linux-mainline for the Radxa
Cubie A7S (Allwinner A733), configured with config/a7s_defconfig: the arm64
defconfig plus what Fedora needs. No firmware is included.

%package devel
Summary:        Headers and build tools for modules of the Linux kernel for the Radxa Cubie A7S
Requires:       kernel-a7s = %{version}-%{release}
# What dkms asks Fedora's kernel-devel for. No kernel-devel-uname-r: its
# version is the uname -r, which an RPM version cannot hold (kver has a '-').
Provides:       kernel-devel = %{version}-%{release}
Provides:       kernel-devel-matched = %{version}-%{release}
Provides:       installonlypkg(kernel)

%description devel
The kernel headers, the configuration, Module.symvers and the build tools
(built for arm64) of kernel-a7s in /usr/src/kernels/%{kver}, linked from
/usr/lib/modules/%{kver}/build. They build modules outside the kernel tree
on the board, also with dkms.

%prep

%build

%install
d=%{buildroot}/usr/lib/modules/%{kver}
mkdir -p "$d/dtb"
tar -C %{buildroot}/usr -xzf %{SOURCE3}
tar -C %{buildroot}/usr -xzf %{SOURCE4}
ln -s /usr/src/kernels/%{kver} "$d/build"
# depmod's output, owned as %ghost as Fedora's kernel owns it: kernel-install
# writes it at install (50-depmod.install) and removes it at removal. The
# same names as %ghost in %files.
rm -f "$d"/modules.{alias,alias.bin,builtin.alias.bin,builtin.bin,dep,dep.bin,devname,softdep,symbols,symbols.bin,weakdep}
install -m 0755 %{SOURCE0} "$d/vmlinuz"
install -m 0644 %{SOURCE1} "$d/config"
tar -C "$d/dtb" -xzf %{SOURCE2}
# What kernel-install puts into /boot, owned as Fedora's kernel owns it: dnf
# finds the running kernel by /boot/vmlinuz-<uname -r>.
mkdir -p %{buildroot}/boot/dtb-%{kver}
touch %{buildroot}/boot/vmlinuz-%{kver} %{buildroot}/boot/config-%{kver} \
  %{buildroot}/boot/initramfs-%{kver}.img
# Fedora's kernel packages do not boot the board: dnf leaves them out.
mkdir -p %{buildroot}/usr/share/dnf5/libdnf.conf.d
cat > %{buildroot}/usr/share/dnf5/libdnf.conf.d/80-kernel-a7s.conf <<'EOC'
# kernel-a7s stands in for Fedora's kernel packages, which do not boot the
# Radxa Cubie A7S: dnf does not install them in its place.
[main]
excludepkgs = kernel, kernel-core, kernel-modules, kernel-modules-core, kernel-modules-extra, kernel-devel, kernel-devel-matched, kernel-uki-*
EOC
# U-Boot loads the device tree from the ESP and fixes it up; grub passes it on.
mkdir -p %{buildroot}/usr/lib/kernel/install.d
cat > %{buildroot}/usr/lib/kernel/install.d/25-a7s-dtb-to-esp.install <<'EOC'
#!/bin/sh
# U-Boot loads the board's device tree from the ESP (/dtb/<fdtfile>), fixes
# it up and hands it to grub, which passes it on to the kernel. Keep that
# copy equal to /boot/dtb, the newest kernel's device trees
# (10-devicetree.install, after 20-grub.install copied them). Without /boot/dtb (a kernel that brings no
# device trees, or FirmwareDT=True in /etc/u-boot.conf) the ESP keeps the ones
# it has.
case "$1" in add|remove) ;; *) exit 0 ;; esac
esp=/boot/efi
rm -rf "$esp/dtb.new"
if [ -d /boot/dtb/ ]; then
	mkdir "$esp/dtb.new" && cp -r /boot/dtb/. "$esp/dtb.new/" &&
		rm -rf "$esp/dtb" && mv "$esp/dtb.new" "$esp/dtb" ||
		echo "could not copy /boot/dtb to $esp/dtb, U-Boot keeps the device tree it had" >&2
else
	echo "no /boot/dtb, $esp/dtb stays as it is" >&2
fi
exit 0
EOC
chmod 0755 %{buildroot}/usr/lib/kernel/install.d/25-a7s-dtb-to-esp.install

%posttrans
/bin/kernel-install add %{kver} /usr/lib/modules/%{kver}/vmlinuz || exit $?

%preun
/bin/kernel-install remove %{kver} || exit $?

%files
%dir /usr/lib/modules/%{kver}
%exclude /usr/lib/modules/%{kver}/build
/usr/lib/modules/%{kver}/*
%ghost %attr(0644, root, root) /usr/lib/modules/%{kver}/modules.alias
%ghost %attr(0644, root, root) /usr/lib/modules/%{kver}/modules.alias.bin
%ghost %attr(0644, root, root) /usr/lib/modules/%{kver}/modules.builtin.alias.bin
%ghost %attr(0644, root, root) /usr/lib/modules/%{kver}/modules.builtin.bin
%ghost %attr(0644, root, root) /usr/lib/modules/%{kver}/modules.dep
%ghost %attr(0644, root, root) /usr/lib/modules/%{kver}/modules.dep.bin
%ghost %attr(0644, root, root) /usr/lib/modules/%{kver}/modules.devname
%ghost %attr(0644, root, root) /usr/lib/modules/%{kver}/modules.softdep
%ghost %attr(0644, root, root) /usr/lib/modules/%{kver}/modules.symbols
%ghost %attr(0644, root, root) /usr/lib/modules/%{kver}/modules.symbols.bin
%ghost %attr(0644, root, root) /usr/lib/modules/%{kver}/modules.weakdep
%ghost %attr(0755, root, root) /boot/vmlinuz-%{kver}
%ghost /boot/dtb-%{kver}
%ghost %attr(0600, root, root) /boot/initramfs-%{kver}.img
%ghost %attr(0644, root, root) /boot/config-%{kver}
/usr/share/dnf5/libdnf.conf.d/80-kernel-a7s.conf
/usr/lib/kernel/install.d/25-a7s-dtb-to-esp.install

%files devel
/usr/lib/modules/%{kver}/build
/usr/src/kernels/%{kver}
