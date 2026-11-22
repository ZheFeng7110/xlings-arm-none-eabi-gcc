-- arm-none-eabi-binutils: GNU binutils for bare-metal Arm (arm-none-eabi), built
-- from source. fromsource:arm-none-eabi-gcc copies this tree into its own prefix
-- before it configures GCC, so the compiler payload is self-contained (GCC finds
-- as/ld in <prefix>/arm-none-eabi/bin, relative to itself).
--
-- Linux: host programs are compiled by xim:gcc against the SubOS's xim:glibc (a
-- sysroot of glibc + linux-headers, as tools/res/build.sh gcc does upstream), with
-- libstdc++ and libgcc linked statically: they need glibc and nothing else.
-- macOS (Apple Silicon): the index has no compiler there; Xcode's clang and SDK
-- build it, and the programs need only the system's libraries (macOS 11 and later).
-- Windows: fromsource:arm-none-eabi-binutils-mingw-cross, cross-built on Linux.
--
-- Host tools the build expects on PATH (not in the index): m4, perl, tar, xz.
package = {
    spec = "1",

    homepage = "https://www.gnu.org/software/binutils",
    name = "arm-none-eabi-binutils",
    description = "GNU binutils for bare-metal Arm (arm-none-eabi)",

    authors = "GNU",
    licenses = "GPL-3.0-or-later",
    repo = "https://sourceware.org/git/binutils-gdb.git",
    docs = "https://sourceware.org/binutils/docs/",

    type = "package",
    namespace = "fromsource",
    archs = {"x86_64", "aarch64"},
    status = "dev",
    categories = {"binutils", "gnu", "cross", "embedded", "arm"},
    keywords = {"arm-none-eabi", "binutils", "cortex-m", "baremetal", "cross"},

    programs = {
        "arm-none-eabi-addr2line", "arm-none-eabi-ar", "arm-none-eabi-as",
        "arm-none-eabi-c++filt", "arm-none-eabi-elfedit", "arm-none-eabi-gprof",
        "arm-none-eabi-ld", "arm-none-eabi-ld.bfd", "arm-none-eabi-nm",
        "arm-none-eabi-objcopy", "arm-none-eabi-objdump", "arm-none-eabi-ranlib",
        "arm-none-eabi-readelf", "arm-none-eabi-size", "arm-none-eabi-strings",
        "arm-none-eabi-strip",
    },

    xvm_enable = true,

    xpm = {
        linux = {
            deps = {
                -- runtime: what makes the SubOS a sysroot for the host compiler
                runtime = { "xim:glibc@2.44.3", "xim:linux-headers@5.11.1" },
                build = { "xim:gcc@16.2.0", "xim:binutils@2.42.1", "xim:make@4.3" },
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
        -- Apple Silicon (xlings has no Intel macOS client). Xcode's clang, make, m4
        -- and perl in /usr/bin: no index packages.
        macosx = {
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
import("xim.libxpkg.xvm")

-- Run as `bash <this> <source dir> <prefix> <build dir> <sysroot (Linux; - on macOS)>`.
local build_sh = [==[
set -euo pipefail
src="$1"; prefix="$2"; w="$3"; S="$4"
target=arm-none-eabi
j="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN)"

# gnu17: the sources predate C23, which GCC 15+ defaults to.
export CFLAGS="-O2" CXXFLAGS="-O2"
if [[ "$(uname -s)" == Darwin ]]; then
    # Xcode's clang and SDK. ZERO_AR_DATE: ar and ld64 record no times.
    export CC="clang -std=gnu17" CXX="clang++ -std=gnu++17" LDFLAGS=""
    export MACOSX_DEPLOYMENT_TARGET=11.0 ZERO_AR_DATE=1
else
    # The host compiler: xim:gcc against the SubOS sysroot (glibc + linux-headers).
    L="$(ls "$S"/lib/ld-linux-*.so.* | head -1)"
    export CC="gcc --sysroot=$S -std=gnu17" CXX="g++ --sysroot=$S -std=gnu++17"
    export LDFLAGS="-Wl,--dynamic-linker=$L -Wl,-rpath,$S/lib -static-libstdc++ -static-libgcc"
fi

rm -rf "$w"; mkdir -p "$w" && cd "$w"
fail() { echo "[arm-none-eabi-binutils] $1 failed; tail of $w/$1.log:" >&2; tail -60 "$w/$1.log" >&2; exit 1; }

"$src/configure" --target=$target --prefix="$prefix" --with-sysroot="$prefix/$target" \
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
# The default linker scripts search the tooldir by its absolute path; it is the
# sysroot's /lib (--with-sysroot=<prefix>/arm-none-eabi), which they search too.
# (-i.orig: the form GNU and BSD sed both take.)
sed -i.orig "s|SEARCH_DIR(\"=$prefix/$target/lib\"); ||" "$prefix/$target"/lib/ldscripts/*
rm -f "$prefix/$target"/lib/ldscripts/*.orig
! grep -rqF "$prefix" "$prefix/$target/lib/ldscripts" || { echo "[arm-none-eabi-binutils] ldscripts still name $prefix" >&2; exit 1; }
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
    log.info("building arm-none-eabi-binutils %s (logs: %s)", pkginfo.version(), workdir)
    local sysroot = is_host("linux") and system.subos_sysrootdir() or "-"
    system.exec(string.format("bash %s %s %s %s %s",
        script, srcdir, prefix, workdir, sysroot))

    if not os.isfile(path.join(prefix, "bin", "arm-none-eabi-as")) then
        raise("arm-none-eabi-binutils: bin/arm-none-eabi-as was not installed")
    end
    os.tryrm(workdir)
    return true
end

function config()
    local bindir = path.join(pkginfo.install_dir(), "bin")
    local binding = package.name .. "@" .. pkginfo.version()
    xvm.add(package.name)
    for _, prog in ipairs(package.programs) do
        xvm.add(prog, { bindir = bindir, binding = binding })
    end
    return true
end

function uninstall()
    xvm.remove(package.name)
    for _, prog in ipairs(package.programs) do
        xvm.remove(prog)
    end
    return true
end
