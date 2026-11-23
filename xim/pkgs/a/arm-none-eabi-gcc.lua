-- arm-none-eabi-gcc: GCC 14.2.0 (C, C++) and binutils 2.43.1 for bare-metal Arm
-- (Cortex-M/R), WITHOUT a C library -- as Homebrew's arm-none-eabi-gcc. The payload is
-- what `xlings install fromsource:arm-none-eabi-gcc@14.2.0` builds (with
-- fromsource:arm-none-eabi-binutils inside), exported by tools/fromsource.sh of
-- https://github.com/ZheFeng7110/xlings-arm-none-eabi-gcc (README.provenance in the
-- payload names the recipe commit, the xlings client and the factory image).
--
-- ⭐ THE C LIBRARY IS A PACKAGE OF ITS OWN, AND SO IS libstdc++.
--
--   newlib-arm-none-eabi              newlib + newlib-nano, Arm GNU Toolchain's names
--   picolibc-arm-none-eabi            (planned)
--   libstdcxx-<libc>-arm-none-eabi    (planned) libstdc++ built against that libc's
--                                     headers by THIS gcc, so its version is this
--                                     package's version: libstdcxx-newlib-arm-none-eabi@14.2.0
--
-- A C library is a sysroot this compiler selects with `--sysroot=<it>/arm-none-eabi`;
-- its specs files then do the rest (`--specs=nano.specs --specs=nosys.specs`, as
-- STM32CubeMX generates). The compiler's own sysroot, `<prefix>/arm-none-eabi`, is
-- relocatable and holds no C library, so without one only freestanding code links
-- (`-nostdlib ... -lgcc`).
--
-- ⚠️ libgcc is built with inhibit_libc (there is no C library at build time), so
-- there is no libgcov: `--coverage` does not link.
--
-- ⚠️ THE MULTILIB SET IS PART OF THE ABI WITH ITS C LIBRARY. It is `rmprofile`
-- (thumb/v6-m/nofp ... thumb/v8-m.main+fp/hard), the set Arm's toolchain carries
-- for M/R profiles; newlib-arm-none-eabi is built by this payload from its own
-- `-print-multi-lib`. A compiler with another list is a new version here, never a
-- rebuild of this one.
--
-- Hosts (each payload's README.provenance says how it was made):
--   linux x86_64/aarch64  built by xim:gcc against xim:glibc; the host programs need
--                         glibc alone (the export checks it, and resets INTERP/RPATH);
--                         elfpatch puts them on xim:glibc at install time
--   windows x86_64        cross-built on Linux (fromsource:arm-none-eabi-gcc-mingw-cross),
--                         linked statically: Windows' own DLLs only; a .zip
--   macosx aarch64        built by Xcode's clang: system libraries only, macOS 11+
-- The target code (libgcc) is the same bytes in all of them.
package = {
    spec = "2",
    homepage = "https://gcc.gnu.org/",
    name = "arm-none-eabi-gcc",
    description = "GCC 14.2.0 and binutils 2.43.1 for bare-metal Arm (arm-none-eabi), without a C library",
    authors = {"GNU"},
    maintainers = {"https://gcc.gnu.org/"},
    licenses = {"GPL-3.0-or-later", "GPL-3.0-or-later WITH GCC-exception-3.1"},
    repo = "https://gcc.gnu.org/git/gcc.git",
    docs = "https://gcc.gnu.org/onlinedocs/gcc/ARM-Options.html",
    type = "package",
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

    -- Built, not mirrored: a version bump is a factory build and a publication,
    -- then an edit here. No `ci` block. Hosted on the building repository's
    -- releases until it moves to xlings-res (then: source = "xlings-res"; the bytes,
    -- and so the hashes, stay the same).
    xpm = {
        linux = {
            source = "https://github.com/ZheFeng7110/xlings-arm-none-eabi-gcc/releases/download/${name}-${version}/${name}-${version}-linux-${arch}.tar.gz",
            deps = {
                runtime = { "xim:glibc@>=2.39" },
                build = { "xim:patchelf@0.18.0" },
            },
            ["latest"] = { ref = "14.2.0" },
            -- The release arm-none-eabi-gcc-14.2.0 (build runs 44453953062 and
            -- 44456719656 of c0b8058 made the same bytes).
            ["14.2.0"] = {
                sha256 = {
                    x86_64 = "b60eea24d60c1aaadc1386164ec6c5312a370c3012c8342bb2b23351dd53aaca",
                    aarch64 = "9cd587d85b468267cf13487205f6a9ac3ce09db0e9bca1d8abc71aa66cc039f1",
                },
            },
        },
        -- Added to the same release by build run 45107607496 of b01941d.
        windows = {
            source = "https://github.com/ZheFeng7110/xlings-arm-none-eabi-gcc/releases/download/${name}-${version}/${name}-${version}-windows-${arch}.zip",
            ["latest"] = { ref = "14.2.0" },
            ["14.2.0"] = {
                sha256 = {
                    x86_64 = "90d1220740b75a91556e2bdbe2df9e3e42af5908fe5c249f8a66359936ab2cc8",
                },
            },
        },
        macosx = {
            source = "https://github.com/ZheFeng7110/xlings-arm-none-eabi-gcc/releases/download/${name}-${version}/${name}-${version}-macosx-${arch}.tar.gz",
            ["latest"] = { ref = "14.2.0" },
            ["14.2.0"] = {
                sha256 = {
                    aarch64 = "4d984923cc0f3967edfdfc529509c1310a9aeb27ec15fa82da803ef8b693bfb2",
                },
            },
        },
    },
}

import("xim.libxpkg.pkginfo")
import("xim.libxpkg.xvm")

function install()
    -- The archive's one directory, arm-none-eabi-gcc-<version>-<os>-<arch>, is the prefix.
    local top = pkginfo.install_file():replace(".tar.gz", ""):replace(".zip", "")
    if not os.isdir(top) then
        raise("arm-none-eabi-gcc payload not found at " .. top)
    end
    os.tryrm(pkginfo.install_dir())
    os.mv(top, pkginfo.install_dir())
    -- The compiler finds as/ld in <prefix>/arm-none-eabi/bin and cc1 under
    -- libexec, relative to itself; a payload missing either installs cleanly
    -- and fails at the first compile.
    local libexec = "libexec/gcc/arm-none-eabi/" .. pkginfo.version()
    local exe = is_host("windows") and ".exe" or ""
    for _, f in ipairs({
        "bin/arm-none-eabi-gcc", "arm-none-eabi/bin/as", "arm-none-eabi/bin/ld",
        libexec .. "/cc1", libexec .. "/cc1plus",
    }) do
        f = f .. exe
        if not os.isfile(path.join(pkginfo.install_dir(), f)) then
            raise("arm-none-eabi-gcc payload is missing " .. f)
        end
    end
    return true
end

function config()
    local bindir = path.join(pkginfo.install_dir(), "bin")
    local release = package.name .. "@" .. pkginfo.version()
    -- The package's name is its C compiler; the other programs bind to it.
    xvm.add(package.name, { bindir = bindir })
    for _, prog in ipairs(package.programs) do
        if prog ~= package.name then
            xvm.add(prog, { bindir = bindir, binding = release })
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
