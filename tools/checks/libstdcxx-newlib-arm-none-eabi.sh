#!/usr/bin/env bash
# Factory checks for fromsource:libstdcxx-newlib-arm-none-eabi, run by
# tools/fromsource.sh on the COPY of the installed tree.
#
#   tools/checks/libstdcxx-newlib-arm-none-eabi.sh <payload> <gcc version>
#
# needs: xim:qemu-arm@9.2.4-1
#
# The sysroot carries a newlib: newlib-arm-none-eabi.sh checks that part (its
# version: NEWLIB_VERSION, or the fromsource:newlib-arm-none-eabi in
# FROMSOURCE_XPKGS, which this was built with). The compiler: see
# common-arm-none-eabi.sh.
set -euo pipefail
p="$1"; version="$2"
die() { printf '[check libstdcxx-newlib-arm-none-eabi] %s\n' "$*" >&2; exit 1; }
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
# shellcheck source-path=SCRIPTDIR source=common-arm-none-eabi.sh
. "$(dirname "${BASH_SOURCE[0]}")/common-arm-none-eabi.sh"

"$gcc/bin/arm-none-eabi-gcc" -dumpversion | grep -qxF "$version" || die "the compiler at $gcc is not GCC $version"

nv="${NEWLIB_VERSION:-}"
if [[ -z "$nv" ]]; then
    found=("${FROMSOURCE_XPKGS:-/nonexistent}"/fromsource-x-newlib-arm-none-eabi/*/)
    [[ ${#found[@]} -eq 1 && -d "${found[0]}" ]] || die "set NEWLIB_VERSION: no single fromsource:newlib-arm-none-eabi in ${FROMSOURCE_XPKGS:-(FROMSOURCE_XPKGS unset)}"
    nv="$(basename "${found[0]}")"
fi
bash "$here/newlib-arm-none-eabi.sh" "$p" "$nv" || die "the newlib in the sysroot failed its checks"
for f in COPYING3 COPYING.RUNTIME; do [[ -f "$p/$f" ]] || die "no $f"; done

# Every multilib: both variants of both libraries, and its c++config.h.
cxxinc="$root/include/c++/$version"
[[ -f "$cxxinc/vector" ]] || die "no C++ headers in include/c++/$version"
for m in $multilibs; do
    for f in libstdc++.a libsupc++.a libstdc++_nano.a libsupc++_nano.a; do
        [[ -f "$root/lib/$m/$f" ]] || die "missing lib/$m/$f"
    done
    d="$cxxinc/arm-none-eabi"; [[ "$m" != . ]] && d="$d/$m"
    [[ -f "$d/bits/c++config.h" ]] || die "missing include/c++/$version/arm-none-eabi/${m#.}/bits/c++config.h"
done
# The nano variant is built without exceptions (Arm's): nothing in it throws.
h="$root/lib/thumb/v7e-m+fp/hard"
[[ "$("$nm" "$h/libstdc++.a" 2>/dev/null | grep -c ' U __cxa_throw$')" -gt 0 ]] || die "the full libstdc++.a throws nothing: is it the nano one?"
[[ "$("$nm" "$h/libstdc++_nano.a" "$h/libsupc++_nano.a" 2>/dev/null | grep -c ' U __cxa_throw$')" -eq 0 ]] \
    || die "libstdc++_nano.a / libsupc++_nano.a throw: not built with -fno-exceptions"
# std::random_device uses no entropy syscall (as Arm's): the string instantiations
# bring it into every link that uses std::runtime_error, and nothing but
# libnosys's stub defines _getentropy.
! "$nm" "$h/libstdc++.a" "$h/libstdc++_nano.a" 2>/dev/null | grep -Eq ' U (getentropy|arc4random)$' \
    || die "libstdc++ calls getentropy/arc4random: a link without libnosys fails"

cd "$t"
m4h=(-mcpu=cortex-m4 -mthumb -mfpu=fpv4-sp-d16 -mfloat-abi=hard)
cubemx=(--specs=nano.specs --specs=nosys.specs)

# The headers are found through the sysroot (arm-none-eabi-gcc 14.2.0 revision 1),
# and the C library's are reached from them.
cat > h.cc <<'EOF'
#include <algorithm>
#include <array>
#include <cassert>
#include <climits>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <memory>
#include <optional>
#include <string>
#include <variant>
#include <vector>
static_assert(PATH_MAX > 0 && sizeof(std::uint32_t) == 4);
int f(std::vector<int>& v) { std::sort(v.begin(), v.end()); return v.empty() ? 0 : v.front(); }
EOF
"${cxx[@]}" -std=c++20 "${m4h[@]}" -c h.cc -o h.o || die "the C++ headers do not compile with --sysroot=<payload>/arm-none-eabi"
"${cxx[@]}" -std=c++20 "${m4h[@]}" --specs=nano.specs -fno-exceptions -c h.cc -o h.o || die "the C++ headers do not compile with nano.specs -fno-exceptions"

# Linked as STM32CubeMX links: nano.specs takes the nano libstdc++.
printf '#include <string>\n#include <cstdio>\nint main() { std::string s(40, (char)0x61); std::printf("%%zu\\n", s.size()); return 0; }\n' > t.cc
took thumb/v7e-m+fp/hard/libstdc++_nano.a "${cxx[@]}" "${m4h[@]}" "${cubemx[@]}" -fno-exceptions t.cc
took thumb/v7e-m+fp/hard/libstdc++.a      "${cxx[@]}" "${m4h[@]}" --specs=nosys.specs t.cc
took thumb/v6-m/nofp/libstdc++_nano.a     "${cxx[@]}" -mcpu=cortex-m0 -mthumb "${cubemx[@]}" -fno-exceptions t.cc

# Run: static construction, containers, strings, a virtual call, and (full
# variant) an exception thrown and caught -- on the M3 and the hard-float M4.
cat > run.cc <<'EOF'
#include <cstdio>
#include <memory>
#include <numeric>
#include <string>
#include <vector>
#ifdef FULL
#include <stdexcept>
#endif
struct Shape { virtual ~Shape() = default; virtual int area() const = 0; };
struct Rect : Shape { int w, h; Rect(int a, int b) : w(a), h(b) {} int area() const override { return w * h; } };
static std::vector<int> table = {1, 2, 3, 4};      // constructed before main
int main()
{
    std::vector<std::unique_ptr<Shape>> shapes;
    shapes.push_back(std::make_unique<Rect>(3, 4));
    std::string s = "c++";
    s += std::to_string(std::accumulate(table.begin(), table.end(), 0));
    volatile float x = 1.5f;
    int caught = 0;
#ifdef FULL
    try { if (x > 1.0f) throw std::runtime_error("thrown"); } catch (const std::exception& e) { caught = (e.what()[0] == 't'); }
#endif
    std::printf("libstdc++: %s %d %d %d\n", s.c_str(), shapes[0]->area(), (int)(x * 2), caught);
    return 0;
}
EOF
"${cxx[@]}" -std=c++17 -mcpu=cortex-m3 -mthumb --specs=nano.specs --specs=rdimon.specs -fno-exceptions -T "$here/mps2.ld" -Wl,--no-warn-rwx-segments run.cc vectors.c -o m3-nano.elf
"${cxx[@]}" -std=c++17 "${m4h[@]}" --specs=nano.specs --specs=rdimon.specs -fno-exceptions -T "$here/mps2.ld" -Wl,--no-warn-rwx-segments run.cc vectors.c -o m4-nano.elf
"${cxx[@]}" -std=c++17 "${m4h[@]}" -DFULL --specs=rdimon.specs -T "$here/mps2.ld" -Wl,--no-warn-rwx-segments run.cc vectors.c -o m4-full.elf
"${cxx[@]}" -std=c++17 -mcpu=cortex-m3 -mthumb -DFULL --specs=rdimon.specs -T "$here/mps2.ld" -Wl,--no-warn-rwx-segments run.cc vectors.c -o m3-full.elf
run mps2-an385 m3-nano.elf "libstdc++: c++10 12 3 0"
run mps2-an386 m4-nano.elf "libstdc++: c++10 12 3 0"
run mps2-an385 m3-full.elf "libstdc++: c++10 12 3 1"
run mps2-an386 m4-full.elf "libstdc++: c++10 12 3 1"

# std::filesystem works over the project's own POSIX functions (design 3.9: Arm's
# libstdc++ returns "Function not implemented" for these). A project provides
# them under their POSIX names -- newlib has none on arm; here, in memory. With
# --gc-sections a link needs only what the operations used call: create_directory
# mkdir, current_path getcwd and pathconf.
cat > fsapp.cc <<'EOF'
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <system_error>
#include <sys/stat.h>
#include <unistd.h>
static char made[32];
extern "C" int mkdir(const char* path, mode_t)
{
    if (made[0]) { errno = EEXIST; return -1; }
    std::strncpy(made, path, sizeof made - 1);
    return 0;
}
extern "C" char* getcwd(char* buf, size_t size)
{
    const char* cwd = "/flash";
    if (size <= std::strlen(cwd)) { errno = ERANGE; return nullptr; }
    return std::strcpy(buf, cwd);
}
extern "C" long pathconf(const char*, int name)
{
    if (name != _PC_PATH_MAX) { errno = EINVAL; return -1; }
    return 64;
}
int main()
{
    std::error_code ec, ec2;
    bool created = std::filesystem::create_directory("logs", ec);
    std::filesystem::path cwd = std::filesystem::current_path(ec2);
    std::printf("fs: %d %d %s %s %d\n", created, ec.value(), made, cwd.c_str(), ec2.value());
    return 0;
}
EOF
"${cxx[@]}" -std=c++17 "${m4h[@]}" --specs=rdimon.specs -Wl,--gc-sections -T "$here/mps2.ld" -Wl,--no-warn-rwx-segments \
    fsapp.cc vectors.c -o m4-fs.elf || die "std::filesystem over the project's mkdir/getcwd/pathconf does not link"
run mps2-an386 m4-fs.elf "fs: 1 0 logs /flash 0"
