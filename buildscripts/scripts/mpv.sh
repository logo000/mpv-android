#!/bin/bash -e

. ../../include/path.sh

build=_build$ndk_suffix

if [ "$1" == "build" ]; then
	true
elif [ "$1" == "clean" ]; then
	rm -rf $build
	exit 0
else
	exit 255
fi

# Apply any patch files staged in <repo-root>/patches/mpv/*.patch BEFORE
# meson setup. Used to ship the ENCODING_AC3 / ENCODING_E_AC3 passthrough
# additions to ao_audiotrack.c that upstream mpv has not adopted (see
# README.md "Patches" section). Each patch is applied with `git apply
# --check` then `git apply` so a partial state cannot wedge the build.
patch_dir="$(realpath ../../../patches/mpv 2>/dev/null || true)"
if [ -d "$patch_dir" ]; then
	for p in "$patch_dir"/*.patch; do
		[ -f "$p" ] || continue
		# Idempotency: skip if already applied (e.g. re-run with cached deps)
		if git apply --reverse --check "$p" >/dev/null 2>&1; then
			echo ">> patch already applied: $(basename "$p")"
			continue
		fi
		echo ">> applying patch: $(basename "$p")"
		git apply --check "$p"
		git apply "$p"
	done
fi

unset CC CXX # meson wants these unset

meson setup $build --cross-file "$prefix_dir"/crossfile.txt \
	--default-library shared \
	-Diconv=disabled -Dlua=enabled \
	-Dlibmpv=true -Dcplayer=false \
	-Dmanpage-build=disabled

ninja -C $build -j$cores
if [ -f $build/libmpv.a ]; then
	echo >&2 "Meson fucked up, forcing rebuild."
	$0 clean
	exec $0 build
fi
DESTDIR="$prefix_dir" ninja -C $build install
