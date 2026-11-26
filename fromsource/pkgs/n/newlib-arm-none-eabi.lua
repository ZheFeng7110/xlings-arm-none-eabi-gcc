-- newlib-arm-none-eabi: newlib and newlib-nano for every multilib of
-- fromsource:arm-none-eabi-gcc, as a sysroot that compiler selects with
-- `--sysroot=<this package>/arm-none-eabi`:
--
--   arm-none-eabi/include/               newlib's headers
--   arm-none-eabi/include/newlib-nano/   nano's newlib.h (nano.specs puts it first)
--   arm-none-eabi/lib/{nano,nosys,rdimon,...}.specs
--   arm-none-eabi/lib/<multilib>/        libc.a libm.a libg.a libnosys.a librdimon.a crt0.o ...
--                                        libc_nano.a libg_nano.a librdimon_nano.a
--
-- The names are Arm GNU Toolchain's, so a project generated for it (STM32CubeMX:
-- `--specs=nano.specs --specs=nosys.specs`) links unchanged. So are the two
-- configures (the manifest of Arm GNU Toolchain 15.3.rel1), one per variant.
--
-- The multilibs are the compiler's (`-print-multi-lib`, rmprofile): newlib's
-- configure builds one per row of the compiler it finds on PATH, the build
-- dependency below. TARGET CODE: the same bytes for every host, built once (on
-- x86_64 Linux); tools/fromsource.sh packs it with --data.
--
-- The host compiler (xim:gcc against the SubOS's xim:glibc, as the other
-- recipes here) is for newlib's top-level configure only, which wants one that
-- works; nothing it compiles is installed.
--
-- Host tools the build expects on PATH (not in the index): perl, tar.
package = {
    spec = "1",

    homepage = "https://sourceware.org/newlib/",
    name = "newlib-arm-none-eabi",
    description = "newlib and newlib-nano for arm-none-eabi-gcc's Cortex-M/R multilibs (nano.specs, nosys.specs, rdimon.specs)",

    authors = "Red Hat, newlib contributors",
    -- A collection of permissive licenses; COPYING.NEWLIB and COPYING.LIBGLOSS
    -- in the payload are the authoritative list.
    licenses = "BSD-3-Clause AND BSD-2-Clause AND MIT",
    repo = "https://sourceware.org/git/newlib-cygwin.git",
    docs = "https://sourceware.org/newlib/docs.html",

    type = "package",
    namespace = "fromsource",
    archs = {"x86_64"},
    status = "dev",
    categories = {"library", "embedded", "arm", "cortex-m", "libc"},
    keywords = {"newlib", "newlib-nano", "arm-none-eabi", "cortex-m", "stm32", "baremetal", "libc"},

    -- No programs: a sysroot. config() registers only the umbrella node.
    xvm_enable = true,

    xpm = {
        linux = {
            deps = {
                -- runtime: what makes the SubOS a sysroot for the host compiler
                runtime = { "xim:glibc@2.44.3", "xim:linux-headers@5.11.1" },
                build = {
                    "arm-none-eabi-gcc@14.2.0",
                    "xim:gcc@16.2.0", "xim:binutils@2.47", "xim:make@4.3",
                },
            },
            ["latest"] = { ref = "4.5.0.20241231" },
            ["4.5.0.20241231"] = {
                url = {
                    GLOBAL = "https://sourceware.org/pub/newlib/newlib-4.5.0.20241231.tar.gz",
                    CN = "https://mirrors.tuna.tsinghua.edu.cn/sourceware/newlib/newlib-4.5.0.20241231.tar.gz",
                },
                -- upstream's sha512.sum lists it; this is the same file's sha256
                sha256 = "33f12605e0054965996c25c1382b3e463b0af91799001f5bb8c0630f2ec8c852",
            },
        },
    },
}

import("xim.libxpkg.pkginfo")
import("xim.libxpkg.system")
import("xim.libxpkg.log")
import("xim.libxpkg.xvm")

-- Run as `bash <this> <source dir> <prefix> <build dir> <sysroot> <arm-none-eabi-gcc prefix>`.
local build_sh = [==[
set -euo pipefail
src="$1"; prefix="$2"; w="$3"; S="$4"; gcc="$5"
target=arm-none-eabi
j="$(nproc)"

# The host compiler, for the top-level configure: xim:gcc against the SubOS sysroot.
L="$(ls "$S"/lib/ld-linux-*.so.* | head -1)"
export CC="gcc --sysroot=$S -std=gnu17" CXX="g++ --sysroot=$S"
export CFLAGS="-O2" CXXFLAGS="-O2" LDFLAGS="-Wl,--dynamic-linker=$L -Wl,-rpath,$S/lib"
# The target compiler and binutils: the build dependency, found by name.
export PATH="$gcc/bin:$PATH"
command -v $target-gcc >/dev/null || { echo "[newlib-arm-none-eabi] no $target-gcc in $gcc/bin" >&2; exit 1; }

# Every function in its own section (--gc-sections in a firmware link drops
# what is unused). The source and build paths are mapped to a fixed one: the
# payload names no build directory and is the same wherever it was built.
map="-ffile-prefix-map=$(dirname "$src")=/xlings-build"

rm -rf "$w"; mkdir -p "$w" && cd "$w"
fail() { echo "[newlib-arm-none-eabi] $1 failed; first errors and tail of $w/$1.log:" >&2
    grep -n -m12 -E "\*\*\*|[Ee]rror[: ]" "$w/$1.log" >&2 || true; echo ... >&2; tail -40 "$w/$1.log" >&2; exit 1; }

common=(--target=$target --disable-nls --disable-newlib-supplied-syscalls
        --enable-newlib-retargetable-locking --enable-newlib-reent-check-verify MAKEINFO=true)
build() {   # variant, CFLAGS_FOR_TARGET, configure flags...
    local v="$1" cflags="$2"; shift 2
    mkdir -p "$w/b-$v" && cd "$w/b-$v"
    CFLAGS_FOR_TARGET="$cflags" "$src/configure" "${common[@]}" --prefix="$w/inst-$v" "$@" \
        >"$w/$v-configure.log" 2>&1 || fail "$v-configure"
    make -j"$j" MAKEINFO=true >"$w/$v-make.log" 2>&1 || fail "$v-make"
    make MAKEINFO=true install >"$w/$v-install.log" 2>&1 || fail "$v-install"
    cd "$w"
}
build newlib "-O2 -ffunction-sections -fdata-sections $map" \
    --enable-newlib-io-long-long --enable-newlib-io-c99-formats --enable-newlib-register-fini \
    --enable-newlib-mb
build nano "-Os -ffunction-sections -fdata-sections $map" \
    --enable-newlib-nano-malloc --disable-newlib-unbuf-stream-opt --enable-newlib-reent-small \
    --disable-newlib-fseek-optimization --enable-newlib-nano-formatted-io \
    --disable-newlib-fvwrite-in-streamio --disable-newlib-wide-orient --enable-lite-exit \
    --enable-newlib-global-atexit

# The sysroot: newlib whole, then nano's libraries beside it under Arm's names,
# and nano's newlib.h where nano.specs looks first.
root="$prefix/$target"
mkdir -p "$prefix"
cp -a "$w/inst-newlib/$target" "$root"
mkdir -p "$root/include/newlib-nano"
cp "$w/inst-nano/$target/include/newlib.h" "$root/include/newlib-nano/newlib.h"
for m in $($target-gcc -print-multi-lib | sed 's/;.*//'); do
    for l in libc libg librdimon; do
        cp "$w/inst-nano/$target/lib/$m/$l.a" "$root/lib/$m/${l}_nano.a"
    done
done
cp "$src/COPYING.NEWLIB" "$src/COPYING.LIBGLOSS" "$prefix/"
find "$prefix" -name '*.la' -delete
]==]

function install()
    local runtime_dir = path.directory(pkginfo.install_file())
    local srcdir = path.join(runtime_dir, "newlib-" .. pkginfo.version())
    -- runtimedir is shared by every package: keep this one's files apart.
    local workdir = path.join(runtime_dir, package.name .. "-" .. pkginfo.version() .. "-build")
    local script = path.join(runtime_dir, package.name .. "-build.sh")
    local prefix = pkginfo.install_dir()

    local gcc = pkginfo.build_dep("arm-none-eabi-gcc")
    if not gcc or not os.isdir(gcc.path) then
        raise("newlib-arm-none-eabi: build dependency arm-none-eabi-gcc not found")
    end

    os.tryrm(prefix)
    io.writefile(script, build_sh)
    log.info("building newlib-arm-none-eabi %s (logs: %s)", pkginfo.version(), workdir)
    system.exec(string.format("bash %s %s %s %s %s %s",
        script, srcdir, prefix, workdir, system.subos_sysrootdir(), gcc.path))

    -- What every link needs; each multilib row is checked by
    -- tools/checks/newlib-arm-none-eabi.sh.
    for _, f in ipairs({
        "include/stdio.h", "include/newlib-nano/newlib.h",
        "lib/nano.specs", "lib/nosys.specs", "lib/rdimon.specs",
        "lib/thumb/v7e-m+fp/hard/libc.a", "lib/thumb/v7e-m+fp/hard/libc_nano.a",
    }) do
        if not os.isfile(path.join(prefix, "arm-none-eabi", f)) then
            raise("newlib-arm-none-eabi: the payload is missing arm-none-eabi/" .. f)
        end
    end
    os.tryrm(workdir)
    return true
end

function config()
    -- Umbrella node only. These are arm-none-eabi TARGET headers and libraries:
    -- on the host include path they would shadow the host libc for every
    -- ordinary build. The compiler is pointed at them with --sysroot.
    xvm.add(package.name)
    return true
end

function uninstall()
    xvm.remove(package.name)
    return true
end
