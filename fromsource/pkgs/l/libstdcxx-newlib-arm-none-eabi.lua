-- libstdcxx-newlib-arm-none-eabi: libstdc++ and libsupc++ of GCC <this version>,
-- built against fromsource:newlib-arm-none-eabi for every multilib of
-- fromsource:arm-none-eabi-gcc, in the full and the nano variant -- inside a
-- COMPLETE SYSROOT that also carries that newlib:
--
--   arm-none-eabi/                       newlib-arm-none-eabi's sysroot, whole, plus
--   arm-none-eabi/include/c++/<version>/ the C++ headers (c++config.h and the other
--                                        per-multilib ones in arm-none-eabi/<multilib>/)
--   arm-none-eabi/lib/<multilib>/        libstdc++.a libsupc++.a libstdc++exp.a ...
--                                        libstdc++_nano.a libsupc++_nano.a
--
-- Why the newlib is in here: a compiler takes one --sysroot, and the C++ headers
-- and libraries must be in the same one as the C library's; xlings packages do not
-- share a directory. The sysroot also cannot go wrong with a newlib other than
-- the one libstdc++ was compiled against. The compiler selects it with
-- `--sysroot=<this package>/arm-none-eabi`, which needs arm-none-eabi-gcc 14.2.0
-- revision 1 or later (its C++ headers are looked for in the sysroot:
-- --with-gxx-include-dir). The names are Arm GNU Toolchain's: nano.specs maps
-- -lstdc++ to -lstdc++_nano.
--
-- How: GCC is configured as fromsource:arm-none-eabi-gcc configures it, with the
-- C library this time (no --without-headers, no --disable-libstdcxx), and
-- --prefix = this package's prefix, so its sysroot is the copied newlib and
-- libstdc++ installs where the payload has it. Only libstdc++ is installed: the
-- compiler and the libgcc built on the way are the compiler package's business.
-- The nano variant is Arm's: -Os, -fno-exceptions, and newlib-nano's newlib.h
-- (what nano.specs makes a compile see: --enable-newlib-reent-small changes
-- struct _reent, through which libstdc++ reaches stdout); a second pass over the
-- same tree, whose libstdc++.a / libsupc++.a are installed as *_nano.a. One set
-- of headers, the full build's, as Arm ships.
--
-- TARGET CODE: one archive for every host, built once (on x86_64 Linux).
-- Host tools the build expects on PATH (not in the index): m4 (in-tree gmp), perl,
-- tar, bzip2, xz, wget (download_prerequisites).
package = {
    spec = "1",

    homepage = "https://gcc.gnu.org/onlinedocs/libstdc++/",
    name = "libstdcxx-newlib-arm-none-eabi",
    description = "libstdc++ (full and nano) for arm-none-eabi-gcc's Cortex-M/R multilibs, in a sysroot with newlib and newlib-nano",

    authors = "GNU, Red Hat, newlib contributors",
    licenses = "GPL-3.0-or-later WITH GCC-exception-3.1 AND BSD-3-Clause AND BSD-2-Clause AND MIT",
    repo = "https://gcc.gnu.org/git/gcc.git",
    docs = "https://gcc.gnu.org/onlinedocs/libstdc++/",

    type = "package",
    namespace = "fromsource",
    archs = {"x86_64"},
    status = "dev",
    categories = {"library", "embedded", "arm", "cortex-m", "c++"},
    keywords = {"libstdc++", "newlib", "newlib-nano", "arm-none-eabi", "cortex-m", "stm32", "baremetal"},

    -- No programs: a sysroot. config() registers only the umbrella node.
    xvm_enable = true,

    xpm = {
        linux = {
            deps = {
                -- runtime: what makes the SubOS a sysroot for the host compiler
                runtime = { "xim:glibc@2.44.3", "xim:linux-headers@5.11.1" },
                build = {
                    "arm-none-eabi-gcc@14.2.0",
                    "newlib-arm-none-eabi@4.5.0.20241231",
                    "xim:gcc@16.2.0", "xim:binutils@2.47", "xim:make@4.3",
                },
            },
            ["latest"] = { ref = "14.2.0" },
            ["14.2.0"] = {
                url = {
                    GLOBAL = "https://ftpmirror.gnu.org/gnu/gcc/gcc-14.2.0/gcc-14.2.0.tar.xz",
                    CN = "https://mirrors.ustc.edu.cn/gnu/gcc/gcc-14.2.0/gcc-14.2.0.tar.xz",
                },
                sha256 = "a7b39bc69cbf9e25826c5a60ab26477001f7c08d85cec04bc0e29cabed6f3cc9",
            },
        },
    },
}

import("xim.libxpkg.pkginfo")
import("xim.libxpkg.system")
import("xim.libxpkg.log")
import("xim.libxpkg.xvm")

-- Run as `bash <this> <source dir> <prefix> <build dir> <sysroot> <arm-none-eabi-gcc prefix> <newlib prefix>`.
local build_sh = [==[
set -euo pipefail
src="$1"; prefix="$2"; w="$3"; S="$4"; gcc="$5"; newlib="$6"
target=arm-none-eabi
j="$(nproc)"
version="$(cat "$src/gcc/BASE-VER")"
root="$prefix/$target"

# The host compiler, as fromsource:arm-none-eabi-gcc's (nothing it builds is
# installed here, but GCC is configured the same way).
L="$(ls "$S"/lib/ld-linux-*.so.* | head -1)"
export CC="gcc --sysroot=$S -std=gnu17" CXX="g++ --sysroot=$S -std=gnu++17"
export CFLAGS="-O2" CXXFLAGS="-O2"
export LDFLAGS="-Wl,--dynamic-linker=$L -Wl,-rpath,$S/lib"
# arm-none-eabi-as/ld/ar: the compiler package's, found by name (the GCC tree's
# as / collect-ld wrappers run what configure found).
export PATH="$gcc/bin:$PATH"
command -v $target-as >/dev/null || { echo "[libstdcxx-newlib-arm-none-eabi] no $target-as in $gcc/bin" >&2; exit 1; }

# The target code: as fromsource:arm-none-eabi-gcc's target libraries (sections
# per function, the source and build paths mapped to a fixed one).
map="-ffile-prefix-map=$(dirname "$src")=/xlings-build"
full="-O2 -ffunction-sections -fdata-sections $map"
nano="-Os -ffunction-sections -fdata-sections $map"
export CFLAGS_FOR_TARGET="$full" CXXFLAGS_FOR_TARGET="$full"
# No getentropy / arc4random for std::random_device (Arm GNU Toolchain's
# libstdc++ has neither). A cross build can only compile-test them, and newlib
# declares both; but a static link reaches random_device from the string
# instantiations (any std::runtime_error does), and _getentropy is a syscall
# neither rdimon nor a project's own syscalls.c provides: the link fails.
# (Autoconf takes a cache variable from the environment.)
export glibcxx_cv_getentropy=no glibcxx_cv_arc4random=no

rm -rf "$w"; mkdir -p "$w" && cd "$w"
fail() { echo "[libstdcxx-newlib-arm-none-eabi] $1 failed; first errors and tail of $w/$1.log:" >&2
    grep -n -m12 -E "\*\*\*|[Ee]rror[: ]" "$w/$1.log" >&2 || true; echo ... >&2; tail -40 "$w/$1.log" >&2; exit 1; }

# The sysroot: newlib-arm-none-eabi whole. GCC's configured sysroot
# (<prefix>/arm-none-eabi) is this directory, so libstdc++ is configured against
# these headers and installs beside them.
mkdir -p "$prefix"
cp -a "$newlib/$target" "$root"
cp "$newlib"/COPYING.NEWLIB "$newlib"/COPYING.LIBGLOSS "$src/COPYING3" "$src/COPYING.RUNTIME" "$prefix/"

# gmp, mpfr, mpc in the tree, as the compiler's build (the source tree is the
# one it used: runtimedir is shared; download_prerequisites skips what is there).
(cd "$src" && sed -i.orig 's#ftp://gcc.gnu.org#https://gcc.gnu.org#' contrib/download_prerequisites \
    && ./contrib/download_prerequisites --no-graphite) >prereq.log 2>&1 || fail prereq

# fromsource:arm-none-eabi-gcc's configure, with the C library: without
# --without-headers and --disable-libstdcxx. No PCH: a .gch is valid only for the
# cc1plus that made it, and that one is not shipped.
mkdir -p b-gcc && cd b-gcc
"$src/configure" --target=$target --prefix="$prefix" --with-sysroot="$root" \
    --with-pkgversion=xlings-fromsource --disable-nls --disable-werror --without-zstd \
    --with-native-system-header-dir=/include --with-multilib-list=rmprofile \
    --with-gxx-include-dir="$root/include/c++/$version" \
    --enable-languages=c,c++ --with-newlib \
    --disable-shared --disable-threads --disable-tls --disable-libssp \
    --disable-libgomp --disable-libquadmath --disable-libffi \
    --disable-decimal-float --enable-checking=release --without-isl \
    --with-static-standard-libraries --with-gnu-as --with-gnu-ld \
    --disable-libstdcxx-pch \
    MAKEINFO=true >"$w/configure.log" 2>&1 || fail configure
make -j"$j" MAKEINFO=true all-gcc all-target-libgcc all-target-libstdc++-v3 >"$w/make.log" 2>&1 || fail make
make MAKEINFO=true install-target-libstdc++-v3 >"$w/install.log" 2>&1 || fail install

# nano: the same libraries again, -Os -fno-exceptions, against newlib-nano's
# newlib.h -- put where newlib.h is for the pass (what nano.specs's
# `-isystem =/include/newlib-nano` does for a user's compile), then put back.
# It keeps the full one's time: libgcc's dependency files name newlib.h, and
# all-target-libstdc++-v3 goes through libgcc first -- a newer newlib.h rebuilt
# libgcc for every multilib, in parallel, and on 4 cores one of its .dep files
# came out truncated ("missing separator"). libgcc is not rebuilt, or this fails.
find "$target" -depth -type d -name 'libstdc++-v3' -exec rm -rf {} +
cp -p "$root/include/newlib.h" "$w/newlib.h.full"
cp "$root/include/newlib-nano/newlib.h" "$root/include/newlib.h"
touch -r "$w/newlib.h.full" "$root/include/newlib.h"
touch -r "$target/libgcc/libgcc.a" "$w/libgcc.stamp"
nano_ok=true
make -j"$j" MAKEINFO=true CFLAGS_FOR_TARGET="$nano" CXXFLAGS_FOR_TARGET="$nano -fno-exceptions" \
    all-target-libstdc++-v3 >"$w/nano-make.log" 2>&1 || nano_ok=false
if [[ "$target/libgcc/libgcc.a" -nt "$w/libgcc.stamp" ]]; then
    cp -p "$w/newlib.h.full" "$root/include/newlib.h"
    echo "[libstdcxx-newlib-arm-none-eabi] the nano pass rebuilt libgcc (see $w/nano-make.log)" >&2; exit 1
fi
$nano_ok && { make MAKEINFO=true CFLAGS_FOR_TARGET="$nano" CXXFLAGS_FOR_TARGET="$nano -fno-exceptions" \
    DESTDIR="$w/nano" install-target-libstdc++-v3 >"$w/nano-install.log" 2>&1 || nano_ok=false; }
cp -p "$w/newlib.h.full" "$root/include/newlib.h"
cmp -s "$root/include/newlib.h" "$newlib/$target/include/newlib.h" || { echo "[libstdcxx-newlib-arm-none-eabi] include/newlib.h is not newlib's" >&2; exit 1; }
$nano_ok || { [[ -f "$w/nano-install.log" ]] && fail nano-install; fail nano-make; }
n="$w/nano$root/lib"
for m in $($target-gcc -print-multi-lib | sed 's/;.*//'); do
    cp "$n/$m/libstdc++.a" "$root/lib/$m/libstdc++_nano.a"
    cp "$n/$m/libsupc++.a" "$root/lib/$m/libsupc++_nano.a"
done
# What the nano configure decided differently (kept for the log: the headers
# shipped are the full build's, as Arm's).
diff "$root/include/c++/$version/$target/bits/c++config.h" \
     "$w/nano$root/include/c++/$version/$target/bits/c++config.h" > "$w/c++config-nano.diff" || true
echo "[libstdcxx-newlib-arm-none-eabi] c++config.h, nano vs full: $(grep -c '^[<>]' "$w/c++config-nano.diff") lines differ"
sed -n '1,40p' "$w/c++config-nano.diff"

# Not part of a sysroot: gdb's pretty printers (they name the build prefix).
rm -rf "${prefix:?}/share" "${prefix:?}/lib"
find "$prefix" \( -name '*.la' -o -name '*-gdb.py' \) -delete
]==]

function install()
    local runtime_dir = path.directory(pkginfo.install_file())
    local srcdir = path.join(runtime_dir, "gcc-" .. pkginfo.version())
    -- runtimedir is shared by every package: keep this one's files apart.
    local workdir = path.join(runtime_dir, package.name .. "-" .. pkginfo.version() .. "-build")
    local script = path.join(runtime_dir, package.name .. "-build.sh")
    local prefix = pkginfo.install_dir()

    local gcc = pkginfo.build_dep("arm-none-eabi-gcc")
    local newlib = pkginfo.build_dep("newlib-arm-none-eabi")
    for name, dep in pairs({ ["arm-none-eabi-gcc"] = gcc, ["newlib-arm-none-eabi"] = newlib }) do
        if not dep or not os.isdir(dep.path) then
            raise("libstdcxx-newlib-arm-none-eabi: build dependency " .. name .. " not found")
        end
    end

    os.tryrm(prefix)
    io.writefile(script, build_sh)
    log.info("building libstdcxx-newlib-arm-none-eabi %s (logs: %s)", pkginfo.version(), workdir)
    system.exec(string.format("bash %s %s %s %s %s %s %s",
        script, srcdir, prefix, workdir, system.subos_sysrootdir(), gcc.path, newlib.path))

    -- What a C++ link needs; each multilib row is checked by
    -- tools/checks/libstdcxx-newlib-arm-none-eabi.sh.
    local v = pkginfo.version()
    for _, f in ipairs({
        "include/stdio.h", "include/c++/" .. v .. "/vector",
        "include/c++/" .. v .. "/arm-none-eabi/thumb/v7e-m+fp/hard/bits/c++config.h",
        "lib/nano.specs",
        "lib/thumb/v7e-m+fp/hard/libstdc++.a", "lib/thumb/v7e-m+fp/hard/libstdc++_nano.a",
        "lib/thumb/v7e-m+fp/hard/libsupc++_nano.a", "lib/thumb/v7e-m+fp/hard/libc_nano.a",
    }) do
        if not os.isfile(path.join(prefix, "arm-none-eabi", f)) then
            raise("libstdcxx-newlib-arm-none-eabi: the payload is missing arm-none-eabi/" .. f)
        end
    end
    os.tryrm(workdir)
    return true
end

function config()
    -- Umbrella node only: target headers and libraries, selected with --sysroot.
    xvm.add(package.name)
    return true
end

function uninstall()
    xvm.remove(package.name)
    return true
end
