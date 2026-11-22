#!/usr/bin/env bash
# Factory checks for fromsource:arm-none-eabi-gcc, run by tools/fromsource.sh on
# the COPY of the installed tree (so every path below is the relocated one), and
# by build.yml on Windows for the Windows payload (in Git Bash).
#
#   tools/checks/arm-none-eabi-gcc.sh <payload> <version>
#
# READELF: a readelf for the ARM objects (default: the payload's own).
set -euo pipefail
p="$1"; version="$2"
readelf="${READELF:-$p/bin/arm-none-eabi-readelf}"
die() { printf '[check arm-none-eabi-gcc] %s\n' "$*" >&2; exit 1; }
g="$p/bin/arm-none-eabi-gcc"
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
# What a program prints, without the CR a Windows program ends its lines with.
out() { "$@" | tr -d '\r'; }

out "$g" --version | head -1 | grep -qF " $version" || die "arm-none-eabi-gcc does not report $version"
# The binutils it carries are fromsource:arm-none-eabi-binutils'.
out "$p/bin/arm-none-eabi-ld" --version | head -1 | grep -q '^GNU ld (xlings-fromsource)' || die "arm-none-eabi-ld is not the fromsource build"

# Relocatable: the sysroot follows the payload to wherever it was copied.
[[ "$(out "$g" -print-sysroot)" -ef "$p/arm-none-eabi" ]] || die "the sysroot is not relocatable: $(out "$g" -print-sysroot)"

# rmprofile: the multilib set the C library packages are built for.
rows="$(out "$g" -print-multi-lib | wc -l)"
[[ "$rows" -eq 29 ]] || die "expected the 29 rmprofile multilibs, got $rows"
want() { # flags... -> the multilib directory they select
    local dir="$1"; shift
    [[ "$(out "$g" "$@" -print-multi-directory)" == "$dir" ]] || die "$* selects $(out "$g" "$@" -print-multi-directory), not $dir"
}
want thumb/v6-m/nofp        -mcpu=cortex-m0 -mthumb
want thumb/v7-m/nofp        -mcpu=cortex-m3 -mthumb
want thumb/v7e-m+fp/hard    -mcpu=cortex-m4 -mthumb -mfpu=fpv4-sp-d16 -mfloat-abi=hard
want thumb/v7e-m+fp/softfp  -mcpu=cortex-m4 -mthumb -mfpu=fpv4-sp-d16 -mfloat-abi=softfp
want thumb/v8-m.main+fp/hard -mcpu=cortex-m33 -mthumb -mfloat-abi=hard
for m in $(out "$g" -print-multi-lib | sed 's/;.*//'); do
    [[ -f "$p/lib/gcc/arm-none-eabi/$version/$m/libgcc.a" ]] || die "no libgcc.a for multilib $m"
done

# No C library and no libstdc++ in the compiler's payload.
[[ -z "$(find "$p/arm-none-eabi/include" -type f 2>/dev/null)" ]] || die "a C library's headers are in the compiler's payload"
[[ -z "$(find "$p" -name 'libstdc++*' -o -name 'libc.a' | head -1)" ]] || die "a target C/C++ library is in the compiler's payload"

# Freestanding C and C++, linked with libgcc (a division needs __aeabi_idiv on m0).
printf 'int f(int a, int b) { return a / b; }\n' > "$t/f.c"
"$g" -mcpu=cortex-m0 -mthumb -nostdlib -Wl,-e,f "$t/f.c" -lgcc -o "$t/f.elf" || die "a freestanding cortex-m0 link with libgcc failed"
out "$p/bin/arm-none-eabi-nm" "$t/f.elf" | grep -q '__aeabi_idiv' || die "libgcc's __aeabi_idiv was not linked"
cat > "$t/k.cc" <<'CC'
#include <stdint.h>
template <typename T> struct Reg { volatile T* p; void set(T v) { *p = v; } };
template <typename A, typename B> constexpr bool same = false;
template <typename A> constexpr bool same<A, A> = true;
static_assert(sizeof(uint32_t) == 4 && !same<uint32_t, uint64_t>);
extern "C" void k(uint32_t* a) { Reg<uint32_t>{a}.set(1u); }
extern "C" float scale(float x, float y) { return x * y; }
CC
"$p/bin/arm-none-eabi-g++" -std=c++20 -ffreestanding -fno-exceptions -fno-rtti -mcpu=cortex-m4 -mthumb \
    -mfpu=fpv4-sp-d16 -mfloat-abi=hard -c "$t/k.cc" -o "$t/k.o" || die "a freestanding C++20 compile failed"
out "$readelf" -A "$t/k.o" | grep -q 'Tag_ABI_VFP_args: VFP registers' || die "cortex-m4 -mfloat-abi=hard is not the VFP-register ABI"
