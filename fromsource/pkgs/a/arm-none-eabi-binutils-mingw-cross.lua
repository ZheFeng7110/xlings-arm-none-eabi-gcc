-- arm-none-eabi-binutils-mingw-cross: fromsource:arm-none-eabi-binutils for a Windows
-- host (x86_64-w64-mingw32), CROSS-BUILT ON LINUX: what it installs is a tree of
-- .exe files for a Windows machine, not programs for the one that built it.
-- fromsource:arm-none-eabi-gcc-mingw-cross copies it into its own prefix, as
-- fromsource:arm-none-eabi-gcc does with fromsource:arm-none-eabi-binutils.
--
-- The same source and configure as fromsource:arm-none-eabi-binutils, plus
-- --build/--host: the programs are compiled by xim:mingw-cross-gcc, linked
-- statically (-static: no libgcc, libstdc++ or winpthread DLL), so they need only
-- Windows' own DLLs. --no-insert-timestamp: a PE header records no build time.
-- The build-side helpers are compiled by xim:gcc against the SubOS's xim:glibc.
-- xim:mingw-cross-gcc runs on the host's own glibc (2.38 or later; tools/fromsource.sh
-- builds this in a Debian 13 image).
--
-- Host tools the build expects on PATH (not in the index): m4, perl, tar, xz.
package = {
    spec = "1",

    homepage = "https://www.gnu.org/software/binutils",
    name = "arm-none-eabi-binutils-mingw-cross",
    description = "GNU binutils for bare-metal Arm (arm-none-eabi), Windows-hosted, cross-built on Linux",

    authors = "GNU",
    licenses = "GPL-3.0-or-later",
    repo = "https://sourceware.org/git/binutils-gdb.git",
    docs = "https://sourceware.org/binutils/docs/",

    type = "package",
    namespace = "fromsource",
    archs = {"x86_64"},
    status = "dev",
    categories = {"binutils", "gnu", "cross", "embedded", "arm", "windows"},
    keywords = {"arm-none-eabi", "binutils", "cortex-m", "baremetal", "cross", "mingw"},

    xpm = {
        linux = {
            deps = {
                -- runtime: what makes the SubOS a sysroot for the build compiler
                runtime = { "xim:glibc@2.44.3", "xim:linux-headers@5.11.1" },
                build = {
                    "xim:mingw-cross-gcc@16.1.0",
                    "xim:gcc@16.2.0", "xim:binutils@2.47", "xim:make@4.3",
                },
            },
            ["latest"] = { ref = "2.43.1" },
            ["2.43.1"] = {
                url = {
                    GLOBAL = "https://ftpmirror.gnu.org/gnu/binutils/binutils-2.43.1.tar.xz",
                    CN = "https://mirrors.ustc.edu.cn/gnu/binutils/binutils-2.43.1.tar.xz",
                },
                sha256 = "13f74202a3c4c51118b797a39ea4200d3f6cfbe224da6d1d95bb938480132dfd",
            },
        },
    },
}

import("xim.libxpkg.pkginfo")
import("xim.libxpkg.system")
import("xim.libxpkg.log")

-- Run as `bash <this> <source dir> <prefix> <build dir> <sysroot>`.
local build_sh = [==[
set -euo pipefail
src="$1"; prefix="$2"; w="$3"; S="$4"
target=arm-none-eabi host=x86_64-w64-mingw32
j="$(nproc)"
build="$("$src/config.guess")"

# The build compiler (helpers run during the build): xim:gcc against the SubOS
# sysroot. The host compiler: xim:mingw-cross-gcc. gnu17: the sources predate C23.
L="$(ls "$S"/lib/ld-linux-*.so.* | head -1)"
# The loader and rpath are in the build compiler itself: gcc/configure probes it
# (gcc/build-*) without LDFLAGS_FOR_BUILD, and its test programs must run (the
# SubOS has no libstdc++: it is linked in).
B="--sysroot=$S -Wl,--dynamic-linker=$L -Wl,-rpath,$S/lib -static-libstdc++ -static-libgcc"
export CC_FOR_BUILD="gcc $B -std=gnu17" CXX_FOR_BUILD="g++ $B -std=gnu++17"
export CFLAGS_FOR_BUILD="-O2" CXXFLAGS_FOR_BUILD="-O2"
# Not the host's (mingw) linker and flags, which they default to.
export LD_FOR_BUILD=ld LDFLAGS_FOR_BUILD=""
# --static, in the compiler: libtool drops -static wherever it is written (and
# binutils would import libwinpthread-1.dll); --static, which GCC takes as the
# same, it passes on. SOURCE_DATE_EPOCH=0: strip (install-strip) rewrites the PE
# header with this as its time; ld writes none (--no-insert-timestamp).
export CC="$host-gcc --static -std=gnu17" CXX="$host-g++ --static -std=gnu++17"
export CFLAGS="-O2" CXXFLAGS="-O2"
export LDFLAGS="-static-libgcc -static-libstdc++ -Wl,--no-insert-timestamp"
export SOURCE_DATE_EPOCH=0

rm -rf "$w"; mkdir -p "$w" && cd "$w"
fail() { echo "[arm-none-eabi-binutils-mingw-cross] $1 failed; first errors and tail of $w/$1.log:" >&2
    grep -n -m12 -E "\*\*\*|[Ee]rror[: ]" "$w/$1.log" >&2 || true; echo ... >&2; tail -40 "$w/$1.log" >&2; exit 1; }

"$src/configure" --build="$build" --host=$host --target=$target \
    --prefix="$prefix" --with-sysroot="$prefix/$target" \
    --with-pkgversion=xlings-fromsource --disable-nls --disable-werror --without-zstd \
    --enable-multilib --enable-interwork --enable-plugins --enable-deterministic-archives \
    --disable-gdb --disable-gdbserver --disable-sim --disable-gprofng \
    --disable-libdecnumber --disable-readline --without-debuginfod \
    MAKEINFO=true >configure.log 2>&1 || fail configure
make -j"$j" MAKEINFO=true >make.log 2>&1 || fail make
make install-strip MAKEINFO=true >install.log 2>&1 || fail install

# Not built (MAKEINFO=true) or naming the build prefix.
rm -rf "$prefix/share/info" "$prefix/share/man"
find "$prefix" -name '*.la' -delete
# As in fromsource:arm-none-eabi-binutils: the tooldir's absolute path is the sysroot's /lib.
sed -i "s|SEARCH_DIR(\"=$prefix/$target/lib\"); ||" "$prefix/$target"/lib/ldscripts/*
! grep -rqF "$prefix" "$prefix/$target/lib/ldscripts" || { echo "[arm-none-eabi-binutils-mingw-cross] ldscripts still name $prefix" >&2; exit 1; }
]==]

function install()
    local runtime_dir = path.directory(pkginfo.install_file())
    local srcdir = path.join(runtime_dir, "binutils-" .. pkginfo.version())
    -- runtimedir is shared by every package: keep this one's files apart.
    local workdir = path.join(runtime_dir, package.name .. "-" .. pkginfo.version() .. "-build")
    local script = path.join(runtime_dir, package.name .. "-build.sh")
    local prefix = pkginfo.install_dir()

    os.tryrm(prefix)
    io.writefile(script, build_sh)
    log.info("building arm-none-eabi-binutils-mingw-cross %s (logs: %s)", pkginfo.version(), workdir)
    system.exec(string.format("bash %s %s %s %s %s",
        script, srcdir, prefix, workdir, system.subos_sysrootdir()))

    if not os.isfile(path.join(prefix, "bin", "arm-none-eabi-as.exe")) then
        raise("arm-none-eabi-binutils-mingw-cross: bin/arm-none-eabi-as.exe was not installed")
    end
    os.tryrm(workdir)
    return true
end

-- Windows programs: nothing to put on this machine's PATH.
function config()
    return true
end

function uninstall()
    return true
end
