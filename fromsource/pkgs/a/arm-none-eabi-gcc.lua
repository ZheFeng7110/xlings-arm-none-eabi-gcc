-- arm-none-eabi-gcc: GCC (C, C++) for bare-metal Arm (Cortex-M/R), WITHOUT a C
-- library -- libgcc is its only target library, as Homebrew's arm-none-eabi-gcc.
-- The payload also carries fromsource:arm-none-eabi-binutils, copied into the
-- same prefix, so it is one self-contained, relocatable toolchain.
--
-- The C library is a package of its own (newlib-arm-none-eabi,
-- picolibc-arm-none-eabi), and so is libstdc++ (libstdcxx-<libc>-arm-none-eabi@<this
-- version>), because libstdc++ is built against a C library's headers. A C library
-- is selected with `--sysroot=<its package>/arm-none-eabi`.
--
-- What the configure decides, and why:
--
--   --with-multilib-list=rmprofile   the Cortex-M/R multilibs Arm's own toolchain
--       carries (thumb/v6-m/nofp ... thumb/v8.1-m.main+pacbti+mve/bp/hard). The C
--       library packages are built by THIS compiler from its `-print-multi-lib`, so
--       the multilib set is part of their ABI: another list is a new version here.
--
--   --with-sysroot=<prefix>/arm-none-eabi --with-native-system-header-dir=/include
--       laid out as newlib installs itself (include/, lib/<multilib>/) and under the
--       prefix, so GCC and ld treat it as RELOCATABLE.
--
--   --without-headers --with-newlib   no C library at build time; libgcc is built
--       with inhibit_libc. Consequence: no libgcov (`--coverage` does not link).
--
--   --with-static-standard-libraries, --without-zstd, in-tree gmp/mpfr/mpc: the
--       host programs need glibc and nothing else (on macOS: the system's libraries).
--
-- Host programs are compiled as fromsource:arm-none-eabi-binutils' are: on Linux by
-- xim:gcc against the SubOS's xim:glibc, on macOS (Apple Silicon) by Xcode's clang.
-- The Windows toolchain is fromsource:arm-none-eabi-gcc-mingw-cross, cross-built on
-- Linux. Host tools expected on PATH (not in the index): m4 (in-tree gmp), perl,
-- tar, bzip2, xz, wget or curl (download_prerequisites).
package = {
    spec = "1",

    homepage = "https://gcc.gnu.org/",
    name = "arm-none-eabi-gcc",
    description = "GCC and binutils for bare-metal Arm (arm-none-eabi), without a C library",

    authors = "GNU",
    licenses = "GPL-3.0-or-later",
    repo = "https://gcc.gnu.org/git/gcc.git",
    docs = "https://gcc.gnu.org/onlinedocs/gcc/ARM-Options.html",

    type = "package",
    namespace = "fromsource",
    archs = {"x86_64", "aarch64"},
    status = "dev",
    categories = {"compiler", "gnu", "cross", "embedded", "arm", "cortex-m"},
    keywords = {"arm-none-eabi", "gcc", "binutils", "cortex-m", "stm32", "baremetal", "cross"},

    programs = {
        "arm-none-eabi-gcc", "arm-none-eabi-g++", "arm-none-eabi-c++", "arm-none-eabi-cpp",
        "arm-none-eabi-gcc-ar", "arm-none-eabi-gcc-nm", "arm-none-eabi-gcc-ranlib",
        "arm-none-eabi-gcov", "arm-none-eabi-gcov-dump", "arm-none-eabi-gcov-tool",
        "arm-none-eabi-lto-dump",
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
                build = {
                    "arm-none-eabi-binutils@2.43.1",
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
        -- Apple Silicon; Xcode's clang, make, m4 and perl in /usr/bin.
        macosx = {
            deps = {
                build = { "arm-none-eabi-binutils@2.43.1" },
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

-- Run as `bash <this> <source dir> <prefix> <build dir> <sysroot (Linux; - on macOS)> <binutils prefix>`.
local build_sh = [==[
set -euo pipefail
src="$1"; prefix="$2"; w="$3"; S="$4"; binutils="$5"
target=arm-none-eabi
j="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN)"
darwin=false; [[ "$(uname -s)" == Darwin ]] && darwin=true

# gnu17/gnu++17: GCC 14 and its gmp predate C23, which GCC 15+ defaults to.
export CFLAGS="-O2" CXXFLAGS="-O2"
if $darwin; then
    # Xcode's clang and SDK (libc++ is the system's). ZERO_AR_DATE: ar and ld64
    # record no times, which the ar wrappers below do on Linux.
    export CC="clang -std=gnu17" CXX="clang++ -std=gnu++17" LDFLAGS=""
    export MACOSX_DEPLOYMENT_TARGET=11.0 ZERO_AR_DATE=1
    static_std=""
else
    # The host compiler: xim:gcc against the SubOS sysroot (glibc + linux-headers).
    L="$(ls "$S"/lib/ld-linux-*.so.* | head -1)"
    export CC="gcc --sysroot=$S -std=gnu17" CXX="g++ --sysroot=$S -std=gnu++17"
    export LDFLAGS="-Wl,--dynamic-linker=$L -Wl,-rpath,$S/lib"
    static_std="--with-static-standard-libraries"
fi

# Target libraries: each function in its own section (what --gc-sections in a
# firmware link needs to drop what is unused). libgcc adds -g of its own; the
# paths its debug info records are mapped to a fixed one, so the payload names
# no build directory and is the same wherever it was built.
export CFLAGS_FOR_TARGET="-O2 -ffunction-sections -fdata-sections -ffile-prefix-map=$(dirname "$src")=/xlings-build"
export CXXFLAGS_FOR_TARGET="$CFLAGS_FOR_TARGET"

rm -rf "$w"; mkdir -p "$w" && cd "$w"
fail() { echo "[arm-none-eabi-gcc] $1 failed; tail of $w/$1.log:" >&2; tail -60 "$w/$1.log" >&2; exit 1; }

# Host archives without timestamps or uids. cc1 embeds a checksum of the objects
# and static libraries it is linked from (libbackend.a, libiberty.a, ...), so an
# archive that records when it was made is a different cc1 on every build.
# xim:binutils' ar is not deterministic by default; these put D on every write.
# (Xcode's ar has no D: ZERO_AR_DATE above does it there.)
if ! $darwin; then
    real_ar="$(command -v ar)"; real_ranlib="$(command -v ranlib)"
    mkdir -p "$w/hostbin"
    cat > "$w/hostbin/ar" <<EOF
#!/bin/sh
case "\$1" in
    --*|*[!A-Za-z-]*) ;;
    *[rqs]*) op="\$1"; shift; exec "$real_ar" "\${op}D" "\$@" ;;   # rc, cru, -cr (libcody)
esac
exec "$real_ar" "\$@"
EOF
    printf '#!/bin/sh\nexec "%s" -D "$@"\n' "$real_ranlib" > "$w/hostbin/ranlib"
    chmod +x "$w/hostbin/ar" "$w/hostbin/ranlib"
    export PATH="$w/hostbin:$PATH"
fi

# binutils first, in this prefix: GCC is configured to find as/ld there.
mkdir -p "$prefix"
cp -a "$binutils"/. "$prefix"/
export PATH="$prefix/bin:$PATH"

# gmp, mpfr, mpc in the tree (linked static), checked against the sha512 GCC
# itself ships (contrib/prerequisites.sha512). No isl: no Graphite.
(cd "$src" && sed -i.orig 's#ftp://gcc.gnu.org#https://gcc.gnu.org#' contrib/download_prerequisites \
    && ./contrib/download_prerequisites --no-graphite) >prereq.log 2>&1 || fail prereq

mkdir -p b-gcc && cd b-gcc
"$src/configure" --target=$target --prefix="$prefix" --with-sysroot="$prefix/$target" \
    --with-pkgversion=xlings-fromsource --disable-nls --disable-werror --without-zstd \
    --with-native-system-header-dir=/include --with-multilib-list=rmprofile \
    --enable-languages=c,c++ --without-headers --with-newlib \
    --disable-shared --disable-threads --disable-tls --disable-libssp \
    --disable-libgomp --disable-libquadmath --disable-libffi --disable-libstdcxx \
    --disable-decimal-float --enable-checking=release --without-isl \
    $static_std --with-gnu-as --with-gnu-ld \
    MAKEINFO=true >"$w/configure.log" 2>&1 || fail configure
make -j"$j" MAKEINFO=true all-gcc all-target-libgcc >"$w/make.log" 2>&1 || fail make
make MAKEINFO=true install-strip-gcc install-target-libgcc >"$w/install.log" 2>&1 || fail install

# Not built (MAKEINFO=true) or naming the build prefix.
rm -rf "$prefix/share/info" "$prefix/share/man"
find "$prefix" -name '*.la' -delete
# install-tools re-run fixincludes against a system header dir there is none of,
# and plugin/ is for building GCC plugins; both record the build paths.
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

    local binutils = pkginfo.build_dep("arm-none-eabi-binutils")
    if not binutils or not os.isdir(binutils.path) then
        raise("arm-none-eabi-gcc: build dependency arm-none-eabi-binutils not found")
    end

    os.tryrm(prefix)
    io.writefile(script, build_sh)
    log.info("building arm-none-eabi-gcc %s (logs: %s)", pkginfo.version(), workdir)
    local sysroot = is_host("linux") and system.subos_sysrootdir() or "-"
    system.exec(string.format("bash %s %s %s %s %s %s",
        script, srcdir, prefix, workdir, sysroot, binutils.path))

    -- The driver finds as/ld in <prefix>/arm-none-eabi/bin and cc1 under libexec,
    -- relative to itself; a payload missing either installs cleanly and fails at
    -- the first compile.
    local libexec = "libexec/gcc/arm-none-eabi/" .. pkginfo.version()
    for _, f in ipairs({
        "bin/arm-none-eabi-gcc", "arm-none-eabi/bin/as", "arm-none-eabi/bin/ld",
        libexec .. "/cc1", libexec .. "/cc1plus",
    }) do
        if not os.isfile(path.join(prefix, f)) then
            raise("arm-none-eabi-gcc: the payload is missing " .. f)
        end
    end
    os.tryrm(workdir)
    return true
end

function config()
    local bindir = path.join(pkginfo.install_dir(), "bin")
    local binding = package.name .. "@" .. pkginfo.version()
    -- The package's name is its C compiler; the other programs bind to it.
    xvm.add(package.name, { bindir = bindir })
    for _, prog in ipairs(package.programs) do
        if prog ~= package.name then
            xvm.add(prog, { bindir = bindir, binding = binding })
        end
    end
    return true
end

function uninstall()
    for _, prog in ipairs(package.programs) do
        xvm.remove(prog)
    end
    return true
end
