#
# This helper is for TKG Linux kernel templates.
#
# based on PKGBUILD from Tk-Glitch <ti3nou@gmail.com>
# based on template of Tk-Glitch; by Joseph Benden <joe@benden.us>

msg2() {
	msg_normal "${1%%\\n}\n"
}

error() {
	msg_error "${1%%\\n}\n"
}

warning() {
	msg_warn "${1%%\\n}\n"
}

plain() {
	msg_normal "${1%%\\n}\n"
}

_process_patch() {
	local _args= _patch= i=$1

	_args="-Np1"
	_patch=${i##*/}

	if [ -f "$PATCHESDIR/${_patch}.args" ]; then
		_args=$(<"$PATCHESDIR/${_patch}.args")
	elif [ -n "$patch_args" ]; then
		_args=$patch_args
	fi

	# Try to guess if its a compressed patch.
	if [[ $i =~ .gz$ ]]; then
		gunzip "$wrksrc/${_patch}"
		_patch=${_patch%%.gz}
	elif [[ $i =~ .bz2$ ]]; then
		bunzip2 "$wrksrc/${_patch}"
		_patch=${_patch%%.bz2}
	elif [[ $i =~ .diff$ ]]; then
		:
	elif [[ $i =~ .patch$ ]]; then
		:
	else
		msg_warn "$pkgver: unknown patch type: $i.\n"
		return 0
	fi

	msg_normal "$pkgver: patching: ${_patch}.\n"
	patch -s ${_args} <"${i}" 2>/dev/null
}

do_patch() {
	: ${wrksrc:=${_srcdir}} # required
	: ${srcdir:=${_srcdir}} # required
	: ${opt_ver:=${_opt_ver}}

	cd "$_srcdir"

	for f in "${_files}"/../mypatches/*; do
		[ ! -f "$f" ] && continue
		if [[ $f =~ ^.*.args$ ]]; then
			continue
		fi
		_process_patch "$f"
	done

	for file in "${_files}"/mypatches/*.myfrag ; do
		msg_normal "$pkgver: copying fragment: ${file##*/}.\n"
		cp -p "${file}" "${_srcdir}"
	done

	mkdir "${_srcdir}"/linux515-tkg-userpatches
	msg_normal "$pkgver: copying userpatches...\n"
	cp -rp "${_files}"/mypatches/${_basekernel}/* \
		"${_srcdir}"/linux515-tkg-userpatches

	ln -sdnf "${_srcdir}/../linux-${_kern_ver_path}" \
		"${_srcdir}/linux-src-git"

	# shellcheck disable=1091
	source "${_files}"/customization.cfg
	# shellcheck disable=1091
	source "${_srcdir}"/linux-tkg-config/prepare

	# Make sure we're in a clean state
	if [ ! -e "$_srcdir"/BIG_UGLY_FROGMINER ]; then
		_tkg_initscript
	fi

	source "$_srcdir"/BIG_UGLY_FROGMINER
}

do_configure() {
	: ${srcdir:=${_srcdir}}
	: ${opt_ver:=${_opt_ver}}

	# reproducible build
	export KBUILD_BUILD_HOST=voidlinux
	export KBUILD_BUILD_USER=$pkgbase
	export KBUILD_BUILD_TIMESTAMP="$(date -Ru${SOURCE_DATE_EPOCH:+d @$SOURCE_DATE_EPOCH})"

	cd "${XBPS_BUILDDIR}" || exit 1
	source "$_srcdir"/BIG_UGLY_FROGMINER

	# shellcheck disable=1091
	source "${_files}"/customization.cfg
	# shellcheck disable=1091
	source "${_srcdir}"/linux-tkg-config/prepare

	if [ -n "$_custom_pkgbase" ]; then
		pkgbase="${_custom_pkgbase}"
	else
		# shellcheck disable=2140
		pkgbase=linux"${_basever}"-tkg
	fi

	cd "${_srcdir}/../linux-${_kern_ver_path}" || exit 1
	_tkg_srcprep
}

do_build() {
	: ${make_cmd:=make}
	: ${srcdir:=${_srcdir}}

	# reproducible build
	export KBUILD_BUILD_HOST=voidlinux
	export KBUILD_BUILD_USER=$pkgbase
	export KBUILD_BUILD_TIMESTAMP="$(date -Ru${SOURCE_DATE_EPOCH:+d @$SOURCE_DATE_EPOCH})"

	cd "${XBPS_BUILDDIR}" || exit 1
	source "$_srcdir"/BIG_UGLY_FROGMINER

	# Clang 10 can't handle these options
	if [ "$_compiler_name" = "-llvm" ]; then
		CFLAGS=${CFLAGS/-fstack-clash-protection -D_FORTIFY_SOURCE=2/}
	fi

	# remove mandatory -O2 flag
	CFLAGS=${CFLAGS/-O2/}
	CFLAGS+=" ${_compiler_opt}"

	cd "${_srcdir}/../linux-${_kern_ver_path}" || exit 1

	# Use custom compiler paths if defined
	if [ "$_compiler_name" = "-llvm" ] && [ -n "${CUSTOM_LLVM_PATH}" ]; then
		export PATH=${CUSTOM_LLVM_PATH}/bin:${CUSTOM_LLVM_PATH}/lib:${CUSTOM_LLVM_PATH}/include:${PATH}
	elif [ -n "${CUSTOM_GCC_PATH}" ]; then
		export PATH=${CUSTOM_GCC_PATH}/bin:${CUSTOM_GCC_PATH}/lib:${CUSTOM_GCC_PATH}/include:${PATH}
	fi

	if [ "$_force_all_threads" == "true" ]; then
		# shellcheck disable=2006
		_force_all_threads="-j$(($(nproc) + 1))"
	else
		# shellcheck disable=2154
		_force_all_threads="${makejobs}"
	fi

	# shellcheck disable=2086,2154
	${make_cmd} ${llvm_opt} ${_force_all_threads} LOCALVERSION=${_make_kernver} bzImage modules
}

do_install() {
	: ${make_cmd:=make}
	: ${make_install_target:=modules_install}

	# reproducible build
	export KBUILD_BUILD_HOST=voidlinux
	export KBUILD_BUILD_USER=$pkgbase
	export KBUILD_BUILD_TIMESTAMP="$(date -Ru${SOURCE_DATE_EPOCH:+d @$SOURCE_DATE_EPOCH})"

	cd "${XBPS_BUILDDIR}" || exit 1
	source "$_srcdir"/BIG_UGLY_FROGMINER

	cd "${_srcdir}/../linux-${_kern_ver_path}" || exit 1

	local arch subarch hdrdest

	echo "Installing modules..."
	${make_cmd} INSTALL_MOD_PATH="$DESTDIR" ${make_install_target}

	hdrdest=${DESTDIR}/usr/src/kernel-headers-${_kernver}

	vinstall .config 644 boot "config-${_kernver}"
	vinstall System.map 644 boot "System.map-${_kernver}"
	vinstall arch/x86/boot/bzImage 644 boot "vmlinuz-${_kernver}"

	# Switch to /usr.
	vmkdir usr
	mv "${DESTDIR}/lib" "${DESTDIR}/usr"

	cd "${DESTDIR}/usr/lib/modules/${_kernver}" || exit 1
	rm -f source build
	ln -sf ../../../src/"kernel-headers-${_kernver}" build

	cd "${_srcdir}/../linux-${_kern_ver_path}" || exit 1

	# Install required headers to build external modules
	install -Dm644 Makefile "${hdrdest}/Makefile"
	install -Dm644 kernel/Makefile "${hdrdest}/kernel/Makefile"
	install -Dm644 .config "${hdrdest}/.config"

	while IFS= read -r -d '' file; do
		mkdir -p "${hdrdest}/$(dirname "$file")"
		install -Dm644 "$file" "${hdrdest}/${file}"
	done < <(find . -name Kconfig\*)

	while IFS= read -r -d '' file; do
		mkdir -p "${hdrdest}/$(dirname "$file")"
		install -Dm644 "$file" "${hdrdest}/${file}"
	done < <(find arch/"${subarch:-$arch}" -name module.lds -o -name Kbuild.platforms -o -name Platform)

	mkdir -p "${hdrdest}/include"
	# Remove firmware stuff provided by the "linux-firmware" pkg.
	rm -rf "${DESTDIR}/usr/lib/firmware"

	for i in acpi asm-generic clocksource config crypto drm generated linux \
		math-emu media net pcmcia scsi sound trace uapi vdso video xen dt-bindings; do
		if [ -d include/$i ]; then
			cp -a include/$i "${hdrdest}/include"
		fi
	done

	cd "${_srcdir}/../linux-${_kern_ver_path}" || exit 1

	mkdir -p "${hdrdest}/arch/x86"
	cp -a arch/x86/include "${hdrdest}/arch/x86"

	# Copy files necessary for later builds, like nvidia and vmware

	cp Module.symvers "${hdrdest}"
	cp -a scripts "${hdrdest}"
	mkdir -p "${hdrdest}/security/selinux"
	cp -a security/selinux/include "${hdrdest}/security/selinux"
	mkdir -p "${hdrdest}/tools/include"
	cp -a tools/include/tools "${hdrdest}/tools/include"

	mkdir -p "${hdrdest}/arch/x86/kernel"
	cp arch/x86/Makefile "${hdrdest}/arch/x86"
	mkdir -p "${hdrdest}/arch/x86/kernel"
	cp arch/x86/kernel/asm-offsets.s "${hdrdest}/arch/x86/kernel"

	# add headers for lirc package
	# pci
	for i in bt8xx cx88 saa7134; do
		mkdir -p "${hdrdest}/drivers/media/pci/${i}"
		cp -a "drivers/media/pci/${i}"/*.h \
			"${hdrdest}/drivers/media/pci/${i}"
	done
	# usb
	for i in cpia2 em28xx pwc; do
		mkdir -p "${hdrdest}/drivers/media/usb/${i}"
		cp -a "drivers/media/usb/${i}"/*.h \
			"${hdrdest}/drivers/media/usb/${i}"
	done
	# i2c
	mkdir -p "${hdrdest}/drivers/media/i2c"
	cp drivers/media/i2c/*.h "${hdrdest}/drivers/media/i2c"
	# shellcheck disable=2043
	for i in cx25840; do
		mkdir -p "${hdrdest}/drivers/media/i2c/${i}"
		cp -a "drivers/media/i2c/${i}"/*.h \
			"${hdrdest}/drivers/media/i2c/${i}"
	done

	# Add md headers
	mkdir -p "${hdrdest}/drivers/md"
	cp drivers/md/*.h "${hdrdest}/drivers/md"

	# Add inotify.h
	mkdir -p "${hdrdest}/include/linux"
	cp include/linux/inotify.h "${hdrdest}/include/linux"

	# Add wireless headers
	mkdir -p "${hdrdest}/net/mac80211/"
	cp net/mac80211/*.h "${hdrdest}/net/mac80211"

	if [ -d include/config/dvb ]; then
		# add dvb headers for external modules
		mkdir -p "${hdrdest}/include/config/dvb/"
		cp include/config/dvb/*.h "${hdrdest}/include/config/dvb/"
	fi

	# add dvb headers for http://mcentral.de/hg/~mrec/em28xx-new
	mkdir -p "${hdrdest}/drivers/media/dvb-frontends"
	cp drivers/media/dvb-frontends/lgdt330x.h \
		"${hdrdest}/drivers/media/dvb-frontends/"
	cp drivers/media/i2c/msp3400-driver.h "${hdrdest}/drivers/media/i2c/"

	# add dvb headers
	mkdir -p "${hdrdest}/drivers/media/usb/dvb-usb"
	cp drivers/media/usb/dvb-usb/*.h "${hdrdest}/drivers/media/usb/dvb-usb/"
	if [ -d drivers/media/usb/dvb-usb-v2 ]; then
		mkdir -p "${hdrdest}/drivers/media/usb/dvb-usb-v2"
		cp drivers/media/usb/dvb-usb-v2/*.h "${hdrdest}/drivers/media/usb/dvb-usb-v2/"
	fi
	mkdir -p "${hdrdest}/drivers/media/dvb-frontends"
	cp drivers/media/dvb-frontends/*.h "${hdrdest}/drivers/media/dvb-frontends/"
	mkdir -p "${hdrdest}/drivers/media/tuners"
	cp drivers/media/tuners/*.h "${hdrdest}/drivers/media/tuners/"

	# Add xfs and shmem for aufs building
	mkdir -p "${hdrdest}/fs/xfs/libxfs"
	mkdir -p "${hdrdest}/mm"
	cp fs/xfs/libxfs/xfs_sb.h "${hdrdest}/fs/xfs/libxfs/xfs_sb.h"

	case $_basever in
		516)
			# Add tools used with BPF
			mkdir -p "${hdrdest}/tools/bpf/resolve_btfids"
			cp tools/bpf/resolve_btfids "${hdrdest}/tools/bpf/resolve_btfids/resolve_btfids"
			;;
		*) ;;
	esac

	# Add objtool binary, needed to build external modules with dkms
	mkdir -p "${hdrdest}/tools/objtool"
	cp tools/objtool/objtool "${hdrdest}/tools/objtool"

	# Remove unneeded architectures
	for arch in alpha avr32 blackfin cris frv h8300 \
		ia64 m* s* um v850 xtensa "arm* p*"; do
		rm -rf "${hdrdest}/arch/${arch}"
	done

	# Keep arch/x86/ras/Kconfig as it is needed by drivers/ras/Kconfig
	mkdir -p "${hdrdest}/arch/x86/ras"
	cp -a arch/x86/ras/Kconfig "${hdrdest}/arch/x86/ras/Kconfig"

	# Extract debugging symbols and compress modules
	# shellcheck disable=2154
	msg_normal "$pkgver: extracting debug info and compressing modules, please wait...\n"
	install -Dm644 vmlinux "${DESTDIR}/usr/lib/debug/boot/vmlinux-${_kernver}"
	(
		cd "${DESTDIR}" || exit 1
		# shellcheck disable=2030
		export DESTDIR
		find ./ -name '*.ko' -print0 \
			| xargs -0r -n1 -P "${XBPS_MAKEJOBS}" "${FILESDIR}/mv-debug"
	) || exit 1

	# ... and run depmod again.
	# shellcheck disable=2031
	depmod -b "${DESTDIR}/usr" -F System.map "${_kernver}"
}
