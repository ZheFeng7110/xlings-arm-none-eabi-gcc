-- arm-none-eabi-gcc-mingw-cross: fromsource:arm-none-eabi-gcc for a Windows host
-- (x86_64-w64-mingw32), CROSS-BUILT ON LINUX (a "Canadian cross": built on Linux,
-- running on Windows, compiling for arm-none-eabi). What it installs is a tree of
-- .exe files for a Windows machine; it carries
-- fromsource:arm-none-eabi-binutils-mingw-cross in the same prefix.
--
-- The same source and configure as fromsource:arm-none-eabi-gcc, plus
-- --build/--host, and only the compiler is built here: libgcc is target code, the
-- same for every host, so it is COPIED from fromsource:arm-none-eabi-gcc (the
-- Linux build of this version) -- as Arm's own Windows toolchain is made. The
-- target libraries are therefore the same bytes on every host, and the multilib
-- set (rmprofile) is the one the C library packages are built for.
--
-- The programs are compiled by xim:mingw-cross-gcc, linked statically, so they
-- need only Windows' own DLLs; --no-insert-timestamp: a PE header records no build
-- time. The build-side helpers are compiled by xim:gcc against the SubOS's
-- xim:glibc. The Linux arm-none-eabi tools of fromsource:arm-none-eabi-gcc are on
-- PATH: configure probes the target assembler with them.
--
-- Host tools expected on PATH (not in the index): m4 (in-tree gmp), perl, tar,
-- bzip2, xz, wget (download_prerequisites).
package = {
    spec = "1",

    homepage = "https://gcc.gnu.org/",
    name = "arm-none-eabi-gcc-mingw-cross",
    description = "GCC and binutils for bare-metal Arm (arm-none-eabi), without a C library, Windows-hosted, cross-built on Linux",

    authors = "GNU",
    licenses = "GPL-3.0-or-later",
    repo = "https://gcc.gnu.org/git/gcc.git",
    docs = "https://gcc.gnu.org/onlinedocs/gcc/ARM-Options.html",

    type = "package",
    namespace = "fromsource",
    archs = {"x86_64"},
    status = "dev",
    categories = {"compiler", "gnu", "cross", "embedded", "arm", "cortex-m", "windows"},
    keywords = {"arm-none-eabi", "gcc", "binutils", "cortex-m", "stm32", "baremetal", "cross", "mingw"},

    xpm = {
        linux = {
            deps = {
                -- runtime: what makes the SubOS a sysroot for the build compiler
                runtime = { "xim:glibc@2.44.3", "xim:linux-headers@5.11.1" },
                build = {
                    "arm-none-eabi-binutils-mingw-cross@2.43.1",
                    "arm-none-eabi-gcc@14.2.0",
                    "xim:mingw-cross-gcc@16.1.0",
                    "xim:gcc@16.2.0", "xim:binutils@2.42.1", "xim:make@4.3",
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

-- Run as `bash <this> <source dir> <prefix> <build dir> <sysroot> <binutils prefix> <Linux gcc prefix>`.
local build_sh = [==[
set -euo pipefail
src="$1"; prefix="$2"; w="$3"; S="$4"; binutils="$5"; native="$6"
target=arm-none-eabi host=x86_64-w64-mingw32
j="$(nproc)"
build="$("$src/config.guess")"
version="$(cat "$src/gcc/BASE-VER")"

# The build compiler: xim:gcc against the SubOS sysroot. The host compiler:
# xim:mingw-cross-gcc. gnu17/gnu++17: GCC 14 and its gmp predate C23.
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
fail() { echo "[arm-none-eabi-gcc-mingw-cross] $1 failed; tail of $w/$1.log:" >&2; tail -60 "$w/$1.log" >&2; exit 1; }

# Archives without timestamps or uids, for the build's and the host's ar alike:
# cc1 embeds a checksum of the static libraries it is linked from (see
# fromsource:arm-none-eabi-gcc).
mkdir -p "$w/hostbin"
for p in "" "$host-"; do
    real_ar="$(command -v "${p}ar")"; real_ranlib="$(command -v "${p}ranlib")"
    cat > "$w/hostbin/${p}ar" <<EOF
#!/bin/sh
case "\$1" in
    --*|*[!A-Za-z-]*) ;;
    *[rqs]*) op="\$1"; shift; exec "$real_ar" "\${op}D" "\$@" ;;   # rc, cru, -cr (libcody)
esac
exec "$real_ar" "\$@"
EOF
    printf '#!/bin/sh\nexec "%s" -D "$@"\n' "$real_ranlib" > "$w/hostbin/${p}ranlib"
    chmod +x "$w/hostbin/${p}ar" "$w/hostbin/${p}ranlib"
done
export PATH="$w/hostbin:$PATH"

# The Windows binutils first, in this prefix, as fromsource:arm-none-eabi-gcc does.
# (Not on PATH: they are .exe files; the Linux arm-none-eabi tools are.)
mkdir -p "$prefix"
cp -a "$binutils"/. "$prefix"/
command -v $target-as >/dev/null || { echo "[arm-none-eabi-gcc-mingw-cross] no $target-as on PATH" >&2; exit 1; }

# gmp, mpfr, mpc in the tree (linked static), checked against GCC's own sha512.
(cd "$src" && sed -i 's#ftp://gcc.gnu.org#https://gcc.gnu.org#' contrib/download_prerequisites \
    && ./contrib/download_prerequisites --no-graphite) >prereq.log 2>&1 || fail prereq

mkdir -p b-gcc && cd b-gcc
"$src/configure" --build="$build" --host=$host --target=$target \
    --prefix="$prefix" --with-sysroot="$prefix/$target" \
    --with-pkgversion=xlings-fromsource --disable-nls --disable-werror --without-zstd \
    --with-native-system-header-dir=/include --with-multilib-list=rmprofile \
    --enable-languages=c,c++ --without-headers --with-newlib \
    --disable-shared --disable-threads --disable-tls --disable-libssp \
    --disable-libgomp --disable-libquadmath --disable-libffi --disable-libstdcxx \
    --disable-decimal-float --enable-checking=release --without-isl \
    --with-static-standard-libraries --with-gnu-as --with-gnu-ld \
    MAKEINFO=true >"$w/configure.log" 2>&1 || fail configure
make -j"$j" MAKEINFO=true all-gcc >"$w/make.log" 2>&1 || fail make
make MAKEINFO=true install-strip-gcc >"$w/install.log" 2>&1 || fail install

# libgcc and its startfiles, per multilib, from the Linux build of this version.
# Only what the compiler's install did not write: its headers stay its own.
n="$native/lib/gcc/$target/$version"; d="$prefix/lib/gcc/$target/$version"
[[ -f "$n/libgcc.a" ]] || { echo "[arm-none-eabi-gcc-mingw-cross] no libgcc.a in $n" >&2; exit 1; }
(cd "$n" && find . -type f) | while IFS= read -r f; do
    [[ -e "$d/$f" ]] && continue
    mkdir -p "$(dirname "$d/$f")"; cp -p "$n/$f" "$d/$f"
done

# Not built (MAKEINFO=true) or naming the build prefix.
rm -rf "$prefix/share/info" "$prefix/share/man"
find "$prefix" -name '*.la' -delete
rm -rf "$prefix/libexec/gcc/$target"/*/install-tools "$prefix/lib/gcc/$target"/*/install-tools \
       "$prefix/lib/gcc/$target"/*/plugin
]==]

function install()
    local runtime_dir = path.directory(pkginfo.install_file())
    local srcdir = path.join(runtime_dir, "gcc-" .. pkginfo.version())
    -- runtimedir is shared by every package: keep this one's files apart.
    local workdir = path.join(runtime_dir, package.name .. "-" .. pkginfo.version() .. "-build")
    local script = path.join(runtime_dir, package.name .. "-build.sh")
    local prefix = pkginfo.install_dir()

    local binutils = pkginfo.build_dep("arm-none-eabi-binutils-mingw-cross")
    local native = pkginfo.build_dep("arm-none-eabi-gcc")
    for name, dep in pairs({ ["arm-none-eabi-binutils-mingw-cross"] = binutils, ["arm-none-eabi-gcc"] = native }) do
        if not dep or not os.isdir(dep.path) then
            raise("arm-none-eabi-gcc-mingw-cross: build dependency " .. name .. " not found")
        end
    end

    os.tryrm(prefix)
    io.writefile(script, build_sh)
    log.info("building arm-none-eabi-gcc-mingw-cross %s (logs: %s)", pkginfo.version(), workdir)
    system.exec(string.format("bash %s %s %s %s %s %s %s",
        script, srcdir, prefix, workdir, system.subos_sysrootdir(), binutils.path, native.path))

    -- What the driver finds relative to itself (as fromsource:arm-none-eabi-gcc
    -- checks), and the copied libgcc.
    local libexec = "libexec/gcc/arm-none-eabi/" .. pkginfo.version()
    for _, f in ipairs({
        "bin/arm-none-eabi-gcc.exe", "arm-none-eabi/bin/as.exe", "arm-none-eabi/bin/ld.exe",
        libexec .. "/cc1.exe", libexec .. "/cc1plus.exe",
        "lib/gcc/arm-none-eabi/" .. pkginfo.version() .. "/libgcc.a",
    }) do
        if not os.isfile(path.join(prefix, f)) then
            raise("arm-none-eabi-gcc-mingw-cross: the payload is missing " .. f)
        end
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
