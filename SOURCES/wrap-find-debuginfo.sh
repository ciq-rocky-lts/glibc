#!/bin/bash
# Wrapper script for find-debuginfo.sh
#
# Usage:
#  wrap-find-debuginfo.sh SYSROOT-PATH SCRIPT-PATH SCRIPT-ARGS...
#
# The wrapper saves the original version of ld.so found in SYSROOT-PATH,
# invokes SCRIPT-PATH with SCRIPT-ARGS, and then restores the
# LDSO-PATH file, followed by note merging and DWZ compression.
# As a result, ld.so has (mostly) unchanged debuginfo even
# after debuginfo extraction.
#
# For libc.so.6 and other shared objects, a set of strategic symbols
# is preserved in .symtab that are frequently used in valgrind
# suppressions and elsewhere.

set -evx

tar_tmp="$(mktemp)"
declare -A libc_dlink_tmp_list
ldso_annobin_sym_tmp_list=""

# Prefer a separately installed debugedit over the RPM-integrated one.
if command -v debugedit >/dev/null ; then
    debugedit=debugedit
else
    debugedit=/usr/lib/rpm/debugedit
fi

cleanup () {
    rm -f "$tar_tmp" ${libc_dlink_tmp_list[@]} $ldso_annobin_sym_tmp_list
}
trap cleanup 0

sysroot_path="$1"
shift
script_path="$1"
shift

# See run_ldso setting in glibc.spec.
ldso_list=`cd "$sysroot_path"; find . -name 'ld-*.so' -type f`
libc_list=`cd "$sysroot_path"; find . -name 'libc-*.so' -type f`
libdl_list=`cd "$sysroot_path"; find . -name 'libdl-*.so' -type f`
libpthread_list=`cd "$sysroot_path"; find . -name 'libpthread-*.so' -type f`
librt_list=`cd "$sysroot_path"; find . -name 'librt-*.so' -type f`

full_list="$ldso_list $libc_list $libdl_list $libpthread_list $librt_list"

# Preserve the original files.
(cd "$sysroot_path"; ls -l $full_list)
(cd "$sysroot_path"; tar cvf "$tar_tmp" $full_list)

# Run the debuginfo extraction.
"$script_path" "$@"

# libc.so.6: Extract the .gnu_debuglink section
for f in $libc_list
do
  dlink_tmp="$(mktemp)"
  libc_dlink_tmp_list["$f"]="$dlink_tmp"
  objcopy -j.gnu_debuglink --set-section-flags .gnu_debuglink=alloc \
      -O binary "$sysroot_path/$f" "$dlink_tmp"
done

# Restore the original files.
(cd "$sysroot_path"; tar xf "$tar_tmp")
(cd "$sysroot_path"; ls -l $full_list)

# Reduce the size of notes.  Primarily for annobin.
for p in $full_list
do
    objcopy --merge-notes "$sysroot_path/$p"
done

# libc.so.6: Restore the .gnu_debuglink section
for f in ${!libc_dlink_tmp_list[@]}
do
  dlink_tmp="${libc_dlink_tmp_list[$f]}"
  objcopy --add-section .gnu_debuglink="$dlink_tmp" "$sysroot_path/$f"
done

# ld.so does not have separated debuginfo and so the debuginfo file
# generated by find-debuginfo is redundant.  Therefore, remove it.
for ldso_debug in `find "$sysroot_path" -name 'ld-*.so*.debug' -type f`
do
  rm -f "$ldso_debug"
done

# libc.so.6 and other shared objects: Reduce to valuable symbols.
# Eliminate file symbols, annobin symbols, and symbols used by the
# glibc build to implement hidden aliases (__EI_*).  We would also
# like to remove __GI_* symbols, but even listing them explicitly (as
# in -K __GI_strlen) still causes strip to remove them, so there is no
# filtering of __GI_* here.  (Debuginfo is gone after this, so no need
# to optimize it.)
for p in $libc_list $libdl_list $libpthread_list $librt_list ; do
    strip -w \
	  -K '*' \
	  -K '!*.c' \
	  -K '!*.os' \
	  -K '!.annobin_*' \
	  -K '!__EI_*' \
	  -K '!__PRETTY_FUNCTION__*' \
	  "$sysroot_path/$p"
done

# ld.so: Rewrite the source file paths to match the extracted
# locations.  First compute the arguments for invoking debugedit.
# See find-debuginfo.sh.
debug_dest_name="/usr/src/debug"
last_arg=
while true ; do
    arg="$1"
    shift || break
    case "$arg" in
	(--unique-debug-src-base)
	    debug_dest_name="/usr/src/debug/$1"
	    shift
	    ;;
	(-*)
	    ;;
	(*)
	    last_arg="$arg"
	    ;;
    esac
done
debug_base_name=${last_arg:-$RPM_BUILD_ROOT}
for p in $ldso_list
do
    $debugedit -b "$debug_base_name" -d "$debug_dest_name" -n "$sysroot_path/$p"

    # Remove the .annobin* symbols (and only them).
    ldso_annobin_sym_tmp="$(mktemp)"
    ldso_annobin_sym_tmp_list+=" $ldso_annobin_sym_tmp"
    if nm --format=posix "$sysroot_path/$p" | cut -d' ' -f1 \
        | grep '^\.annobin' > "$ldso_annobin_sym_tmp"; then
        objcopy --strip-symbols="$ldso_annobin_sym_tmp" "$sysroot_path/$p"
    fi
done

# Apply single-file DWARF optimization.
for ldso in $ldso_list
do
    dwz "$sysroot_path/$p"
done