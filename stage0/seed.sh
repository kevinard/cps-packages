#!/usr/bin/env bash
# Stage 0: assemble the bootstrap toolchain from this Arch Linux host and
# publish it to a local, throwaway repository under the publisher "seed".
#
# THE SEED IS UNTRUSTED. It is whatever compiler, binutils, glibc, and
# utilities this host happens to have, copied file by file. Packages built
# with it are only as trustworthy as the host. Stage 1 rebuilds gcc,
# binutils, and glibc with CPS from pinned sources, and stage 2 rebuilds
# the tree with the stage-1 toolchain until it reaches a fixed point; after
# that no recipe pins "seed". See docs/bootstrap.md.
#
# usage: stage0/seed.sh [--force]
#
# Writes .cache/stage0/repo (the signed seed repository) and
# .cache/keys/seed.trust.json, using the key .cache/keys/seed.der. A
# second run is a no-op unless --force rebuilds the seed, which changes its
# catalog digest, so recipes must be repinned (tools/build.sh does that).
#
# Environment:
#   CPS                  cps binary (default: the pinned build, tools/cps.sh)
#   STAGE0_EXTRA_ROOTS   colon-separated roots searched after / for tools the
#                        host lacks, such as an unpacked gperf or bc package
set -euo pipefail
unset LD_LIBRARY_PATH LD_PRELOAD GCC_EXEC_PREFIX COMPILER_PATH LIBRARY_PATH CPATH C_INCLUDE_PATH
export LC_ALL=C
umask 022
# shellcheck source=../tools/lib.sh
source "$(dirname -- "$0")/../tools/lib.sh"
export PATH=/usr/bin:/bin

force=false
case ${1:-} in
    '') ;;
    --force) force=true ;;
    *) die 'usage: stage0/seed.sh [--force]' ;;
esac
command -v pacman >/dev/null || die 'stage0 copies the toolchain of an Arch Linux host'
[[ $arch == x86_64 ]] || die 'stage0 is written for x86_64 hosts'
cps=$(cps_binary)
stage0=$cache/stage0
if [[ -f $stage0/repo/current && $force == false ]]; then
    note "seed already published: $(cat "$stage0/repo/current") (use --force to rebuild)"
    exit 0
fi
rm -rf -- "$stage0"
mkdir -p -- "$stage0"
work=$(mktemp -d "$stage0/.work.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
IFS=: read -r -a extra_roots <<< "${STAGE0_EXTRA_ROOTS:-}"

# The host path of a tool: /usr/bin first, then each extra root.
host_tool() {
    local name=$1 root
    for root in "" "${extra_roots[@]}"; do
        if [[ -x $root/usr/bin/$name ]]; then
            printf '%s\n' "$root/usr/bin/$name"
            return
        fi
    done
    die "the host has no $name; install it or add a root that has it to STAGE0_EXTRA_ROOTS"
}

copy_file() {
    local tree=$1 source=$2 path=$3
    mkdir -p -- "$tree/${path%/*}"
    cp -L -- "$source" "$tree/$path"
}

# TREE SOURCE PATH copies an ELF program with its interpreter and the
# shared libraries it loads.
copy_elf() {
    local tree=$1 source=$2 path=$3 interpreter loader dependencies library relative
    copy_file "$tree" "$source" "$path"
    interpreter=$(readelf -l "$source" | sed -n 's/^.*Requesting program interpreter: \([^]]*\)].*$/\1/p')
    [[ -n $interpreter ]] || return 0
    copy_file "$tree" "$interpreter" "${interpreter#/}"
    loader=$(realpath -- "$interpreter")
    copy_file "$tree" "$loader" "${loader#/}"
    dependencies=$(ldd "$source")
    if [[ $dependencies == *'not found'* ]]; then
        die "missing shared library for $source: $dependencies"
    fi
    while IFS= read -r library; do
        library=$(realpath -ms -- "$library")
        relative=${library#/}
        # rustup keeps the Rust sysroot in the home directory.
        if [[ -n ${rust_root:-} && $library == "$rust_root/"* ]]; then
            relative="usr/${library#"$rust_root/"}"
        fi
        copy_file "$tree" "$library" "$relative"
    done < <(awk '$2 == "=>" && $3 ~ /^\// { print $3 }' <<< "$dependencies")
}

# TREE LIST copies the shared libraries that each ELF file named in LIST
# loads and TREE lacks, so publication finds no library requirement that
# nothing in the seed provides. Python and Perl extension modules are
# optional: one that needs a library the tree does not already have is
# dropped instead. Otherwise the seed would carry host copies of libraries
# that Canopa packages itself (Python's _sqlite3 and _uuid would bring
# libsqlite3 and libuuid, which then collide with library/sqlite and
# system/util-linux in a toolchain), and layers would collide with each
# other. A module whose library the host lacks cannot load anyway.
complete_libraries() {
    local tree=$1 list=$2 file dependencies library relative missing
    while IFS= read -r path; do
        file=$tree/$path
        [[ -f $file && ! -L $file ]] || continue
        [[ $file == *.so || $file == *.so.* || -x $file ]] || continue
        [[ $(head -c 4 -- "$file" | od -An -tx1 | tr -d ' \n') == 7f454c46 ]] || continue
        readelf -d -- "$file" 2>/dev/null | grep -q '(NEEDED)' || continue
        dependencies=$(ldd -- "$file" 2>/dev/null) || continue
        if [[ $path == */lib-dynload/* || $path == */auto/*.so ]]; then
            missing=$(awk -v tree="$tree" '$2 == "=>" && $3 ~ /^\// && index($3, tree "/") != 1 { print $1 }' <<< "$dependencies" |
                while read -r library; do
                    [[ -e $tree/usr/lib/$library ]] || printf '%s ' "$library"
                done)
            if [[ -n $missing || $dependencies == *'not found'* ]]; then
                note "dropping optional module $path: needs ${missing:-a library the host lacks}"
                rm -- "$file"
                continue
            fi
        fi
        if [[ $dependencies == *'not found'* ]]; then
            note "dropping $path: $(awk '/not found/ { printf "%s ", $1 }' <<< "$dependencies")not found"
            rm -- "$file"
            continue
        fi
        while IFS= read -r library; do
            [[ $library == "$tree"/* ]] && continue
            library=$(realpath -ms -- "$library")
            relative=${library#/}
            [[ -e $tree/$relative ]] || copy_file "$tree" "$library" "$relative"
        done < <(awk '$2 == "=>" && $3 ~ /^\// { print $3 }' <<< "$dependencies")
    done < "$list"
}

copy_tools() {
    local tree=$1 tool
    shift
    for tool; do
        copy_elf "$tree" "$(host_tool "$tool")" "usr/bin/$tool"
    done
}

# --- build/seed-c: the C toolchain and the utilities every recipe uses ---
base=$work/seed-c
copy_elf "$base" /usr/bin/bash bin/sh
ln -s sh "$base/bin/bash"
copy_tools "$base" ar as awk basename bzip2 cat chmod cmp cp cut date dd diff dirname echo env \
    expr find gcc grep gzip head install ld ln ls make mkdir mktemp mv nm objcopy objdump od \
    patch pkg-config printf ranlib readelf readlink realpath rm rmdir sed sleep sort stat strip \
    tail tar touch tr true uname uniq wc whoami xargs xz yes
ln -s gcc "$base/usr/bin/cc"
for tool in cc1 collect2 lto-wrapper; do
    binary=$(gcc -print-prog-name="$tool")
    copy_elf "$base" "$binary" "${binary#/}"
done
for file in crt1.o Scrt1.o crti.o crtn.o crtbegin.o crtbeginS.o crtbeginT.o crtend.o \
    crtendS.o liblto_plugin.so libgcc.a libgcc_eh.a libgcc_s.so libgcc_s.so.1 libc.so \
    libm.so libmvec.so.1; do
    path=$(realpath -ms -- "$(gcc -print-file-name="$file")")
    copy_file "$base" "$path" "${path#/}"
done
for file in libgcc_s_asneeded.so libatomic_asneeded.a libatomic_asneeded.so \
    libatomic.a libatomic.so libatomic.so.1; do
    path=$(gcc -print-file-name="$file")
    if [[ $path == /* ]]; then
        path=$(realpath -ms -- "$path")
        copy_file "$base" "$path" "${path#/}"
    fi
done
gcc_include=$(gcc -print-file-name=include)
mkdir -p -- "$base/${gcc_include#/}"
cp -RL -- "$gcc_include/." "$base/${gcc_include#/}/"
# glibc and kernel headers, and glibc's static archives for static builds.
while IFS= read -r file; do
    copy_file "$base" "$file" "${file#/}"
done < <(pacman -Qlq glibc linux-api-headers | awk '/^\/usr\/include\/.*[^\/]$/ || /^\/usr\/lib\/[^/]+\.a$/')

(cd -- "$base" && find . -type f -printf '%P\n') > "$work/seed-c.files"
complete_libraries "$base" "$work/seed-c.files"

# --- system/elf-runtime: the loader and C/GCC runtime the seed programs load ---
# It is its own package so that the canopa recipe system/elf-runtime can
# repackage exactly these bytes for images until stage 1 builds glibc.
runtime=$work/elf-runtime
for path in usr/lib/{ld-linux-x86-64.so.2,libc.so.6,libm.so.6,libgcc_s.so.1}; do
    install -Dm755 "$base/$path" "$runtime/$path"
    rm -- "$base/$path"
done
install -d "$runtime/lib64"
ln "$runtime/usr/lib/ld-linux-x86-64.so.2" "$runtime/lib64/ld-linux-x86-64.so.2"
rm -- "$base/lib64/ld-linux-x86-64.so.2"
rmdir -- "$base/lib64"

# LAYER TOOL... assembles a layer on top of seed-c and keeps only the paths
# that seed-c and elf-runtime do not already ship, so no path has two owners.
layer_tree() {
    local name=$1
    mkdir -p -- "$work/full-$name"
    cp -a -- "$base/." "$runtime/." "$work/full-$name/"
}
layer_finish() {
    local name=$1 full
    full=$work/full-$name
    (cd -- "$base" && find . ! -type d -printf '%P\n'; cd -- "$runtime" && find . ! -type d -printf '%P\n') \
        | sort -u > "$work/$name.below"
    new_paths() {
        (cd -- "$full" && find . ! -type d -printf '%P\n') | sort > "$work/$name.all"
        comm -23 "$work/$name.all" "$work/$name.below" > "$work/$name.list"
    }
    new_paths
    complete_libraries "$full" "$work/$name.list"
    new_paths
    # Layers may be combined in one toolchain, so no two may share a path.
    touch "$work/layers.list"
    if comm -12 "$work/layers.list" "$work/$name.list" | grep -q .; then
        comm -12 "$work/layers.list" "$work/$name.list" >&2
        die "layer $name shares the paths above with an earlier layer"
    fi
    sort -u -o "$work/layers.list" "$work/layers.list" "$work/$name.list"
    mkdir -p -- "$work/$name"
    tar -C "$full" -cf - --no-recursion -T "$work/$name.list" | tar -C "$work/$name" -xf -
    rm -rf -- "$full"
}

# --- build/seed-rust: rustc and cargo, for system/cps ---
rust_root=$(rustc --print sysroot)
rust_host=$(rustc -vV | sed -n 's/^host: //p')
[[ -n $rust_host ]] || die 'cannot determine the Rust host triple'
layer_tree seed-rust
for tool in rustc cargo; do
    copy_elf "$work/full-seed-rust" "$rust_root/bin/$tool" "usr/bin/$tool"
done
mkdir -p -- "$work/full-seed-rust/usr/lib/rustlib"
cp -RL -- "$rust_root/lib/rustlib/$rust_host" "$work/full-seed-rust/usr/lib/rustlib/"
layer_finish seed-rust
unset rust_root

# --- build/seed-meson: Python, Meson, Ninja, and gperf, for systemd ---
layer_tree seed-meson
copy_tools "$work/full-seed-meson" id ninja python3 gperf
ln -s python3 "$work/full-seed-meson/usr/bin/python"
copy_file "$work/full-seed-meson" /usr/bin/meson usr/bin/meson
python_lib=$(python3 -c 'import sysconfig; print(sysconfig.get_path("stdlib"))')
while IFS= read -r path; do
    copy_file "$work/full-seed-meson" "$path" "${path#/}"
done < <(pacman -Qlq python | awk -v dir="$python_lib/" 'index($0, dir) == 1 && !/\/$|__pycache__|\/site-packages\//')
site=$python_lib/site-packages
mkdir -p -- "$work/full-seed-meson$site"
for module in mesonbuild packaging markupsafe jinja2 elftools; do
    found=
    for root in "" "${extra_roots[@]}"; do
        if [[ -d $root$site/$module ]]; then found=$root$site/$module; break; fi
    done
    [[ -n $found ]] || die "the host has no Python module $module; add a root with it to STAGE0_EXTRA_ROOTS"
    cp -RL -- "$found" "$work/full-seed-meson$site/"
done
find "$work/full-seed-meson" -name __pycache__ -prune -exec rm -rf {} +
layer_finish seed-meson

# --- build/seed-kernel: what Kbuild needs beyond the C toolchain ---
layer_tree seed-kernel
copy_tools "$work/full-seed-kernel" bison flex m4 sha1sum bc cpio perl kmod
ln -s kmod "$work/full-seed-kernel/usr/bin/depmod"
for path in usr/include/{gelf,libelf}.h usr/lib/{libelf.so.1,pkgconfig/libelf.pc}; do
    copy_file "$work/full-seed-kernel" "/$path" "$path"
done
ln -s libelf.so.1 "$work/full-seed-kernel/usr/lib/libelf.so"
mkdir -p -- "$work/full-seed-kernel/usr/share"
cp -RL -- /usr/share/bison "$work/full-seed-kernel/usr/share/"
# perl needs its own library tree.
perl_lib=$(perl -MConfig -e 'print $Config{privlib}')
perl_arch=$(perl -MConfig -e 'print $Config{archlib}')
for dir in "$perl_lib" "$perl_arch"; do
    mkdir -p -- "$work/full-seed-kernel${dir}"
    cp -RL --remove-destination -- "$dir/." "$work/full-seed-kernel${dir}/"
done
layer_finish seed-kernel

# --- publish ---
keypair seed
repository "$stage0/repo" seed seed
version=1.0.0-0
publish() {
    local name=$1 proto=$2
    shift 2
    "$cps" manifest generate --proto "$proto" --publisher seed --version "$version" \
        --architecture "$arch" --uid 0 --gid 0 "$name" > "$work/manifest.kdl"
    local require
    for require; do
        sed -i "/^package .* {\$/a\\    require \"$require\"" "$work/manifest.kdl"
    done
    sed -i "s|^package \"$name\" |&summary=\"Stage 0 seed: untrusted host toolchain\" |" "$work/manifest.kdl"
    cp -- "$work/manifest.kdl" "$stage0/${name//\//-}.kdl"
    "$cps" publish --repo "$stage0/repo" --proto "$proto" --signing-key "$cache/keys/seed.der" \
        "$work/manifest.kdl" >&2
}
publish system/elf-runtime "$runtime"
publish build/seed-c "$base" system/elf-runtime
publish build/seed-rust "$work/seed-rust" build/seed-c
publish build/seed-meson "$work/seed-meson" build/seed-c
publish build/seed-kernel "$work/seed-kernel" build/seed-c
{
    printf '# Host the stage0 seed was taken from. Untrusted: see stage0/README.md.\n'
    printf 'host-kernel %s\n' "$(uname -r)"
    pacman -Q glibc gcc binutils linux-api-headers make bash python meson ninja perl 2>/dev/null
    printf 'rustc %s\n' "$(rustc -V)"
} > "$stage0/host.txt"
note "published seed catalog $(cat "$stage0/repo/current")"
