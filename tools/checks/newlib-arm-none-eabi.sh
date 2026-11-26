#!/usr/bin/env bash
# Factory checks for fromsource:newlib-arm-none-eabi, run by tools/fromsource.sh on
# the COPY of the installed tree (the sysroot is checked where it was copied to).
# libstdcxx-newlib-arm-none-eabi.sh runs it too, on the newlib its sysroot carries.
#
#   tools/checks/newlib-arm-none-eabi.sh <payload> <newlib version>
#
# needs: xim:qemu-arm@9.2.4-1
#
# The compiler is the one the package was built with (common-arm-none-eabi.sh:
# ARM_NONE_EABI_GCC, or FROMSOURCE_XPKGS).
set -euo pipefail
p="$1"; version="$2"
die() { printf '[check newlib-arm-none-eabi] %s\n' "$*" >&2; exit 1; }
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
# shellcheck source-path=SCRIPTDIR source=common-arm-none-eabi.sh
. "$(dirname "${BASH_SOURCE[0]}")/common-arm-none-eabi.sh"

# This newlib (newlib-<x.y.z>.<date>: _NEWLIB_VERSION is x.y.z).
grep -qF "#define _NEWLIB_VERSION \"${version%.*}\"" "$root/include/_newlib_version.h" \
    || die "the headers are not newlib ${version%.*}: $(grep _NEWLIB_VERSION "$root/include/_newlib_version.h" | head -1)"
for f in COPYING.NEWLIB COPYING.LIBGLOSS; do [[ -f "$p/$f" ]] || die "no $f"; done

# Every multilib of the compiler, and no other: each row complete.
want_files="libc.a libm.a libg.a libnosys.a librdimon.a crt0.o rdimon-crt0.o libc_nano.a libg_nano.a librdimon_nano.a"
for m in $multilibs; do
    for f in $want_files; do
        [[ -f "$root/lib/$m/$f" ]] || die "missing lib/$m/$f"
    done
done
have="$(cd "$root/lib" && find . -name libc.a | sed 's|^\./||; s|/\{0,1\}libc\.a$||; s|^$|.|' | sort)"
[[ "$have" == "$(sort <<<"$multilibs")" ]] || die "the multilib directories are not the compiler's: $(comm -3 <(echo "$have") <(sort <<<"$multilibs") | tr -s ' \t\n' ' ')"
for s in nano nosys rdimon; do
    [[ -f "$root/lib/$s.specs" ]] || die "missing lib/$s.specs"
done
[[ -f "$root/include/newlib-nano/newlib.h" ]] || die "missing include/newlib-nano/newlib.h"

cd "$t"
m4h=(-mcpu=cortex-m4 -mthumb -mfpu=fpv4-sp-d16 -mfloat-abi=hard)
m4s=(-mcpu=cortex-m4 -mthumb -mfpu=fpv4-sp-d16 -mfloat-abi=softfp)
cubemx=(--specs=nano.specs --specs=nosys.specs)
printf '#include <stdio.h>\nint main(void) { printf("%%d\\n", 42); return 0; }\n' > t.c

# Linked as STM32CubeMX links: which archive each row takes.
took thumb/v7e-m+fp/hard/libc_nano.a   "${cc[@]}" "${m4h[@]}" "${cubemx[@]}" t.c
took thumb/v7e-m+fp/softfp/libc_nano.a "${cc[@]}" "${m4s[@]}" "${cubemx[@]}" t.c
took thumb/v6-m/nofp/libc_nano.a       "${cc[@]}" -mcpu=cortex-m0 -mthumb "${cubemx[@]}" t.c
took thumb/v7-m/nofp/libc.a            "${cc[@]}" -mcpu=cortex-m3 -mthumb --specs=nosys.specs t.c
took thumb/v8-m.main+fp/hard/libc_nano.a "${cc[@]}" -mcpu=cortex-m33 -mthumb -mfloat-abi=hard "${cubemx[@]}" t.c
# The hard-float row is hard float, not soft-float code in a hard-float directory.
"${cc[@]}" "${m4h[@]}" "${cubemx[@]}" t.c -o t.elf
"$readelf" -A t.elf | grep -q 'Tag_ABI_VFP_args: VFP registers' || die "cortex-m4 hard float: not the VFP-register ABI"

# nano.specs puts nano's newlib.h first; without it the full one is seen.
echo '#include <stdio.h>' | "${cc[@]}" "${m4h[@]}" --specs=nano.specs -E -dM - | grep -q _NANO_FORMATTED_IO \
    || die "nano.specs does not select include/newlib-nano"
! echo '#include <stdio.h>' | "${cc[@]}" "${m4h[@]}" -E -dM - | grep -q _NANO_FORMATTED_IO \
    || die "the full newlib.h is not the default"

# limits.h reaches newlib's (the compiler's own includes it, revision 1 of
# arm-none-eabi-gcc 14.2.0): what Arm GNU Toolchain's limits.h gives -- newlib's
# PATH_MAX and ARG_MAX, and its MB_LEN_MAX: 8 with --enable-newlib-mb, 1 in nano,
# which has no multibyte support.
cat > l.c <<'EOF'
#include <limits.h>
#if !defined _LIBC_LIMITS_H_ || PATH_MAX != 1024 || ARG_MAX != 65536
#error not the limits of the C library
#endif
#if MB_LEN_MAX != WANT_MB_LEN_MAX
#error MB_LEN_MAX is not the C library value
#endif
int x = PATH_MAX;
EOF
"${cc[@]}" "${m4h[@]}" -DWANT_MB_LEN_MAX=8 -c l.c -o l.o || die "<limits.h> with newlib: not newlib's limits (PATH_MAX 1024, ARG_MAX 65536, MB_LEN_MAX 8)"
"${cc[@]}" "${m4h[@]}" --specs=nano.specs -DWANT_MB_LEN_MAX=1 -c l.c -o l.o || die "<limits.h> with newlib-nano: MB_LEN_MAX is not 1"

# Run: malloc, string functions, float (VFP on the M4), printf over semihosting.
cat > run.c <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(void)
{
    char *p = malloc(32);
    strcpy(p, "heap");
    volatile float x = 3.25f;
    printf("newlib: %s %d.%02d", p, (int)(x * 4), (int)(x * 400) % 100);
#ifdef FULL
    printf(" %.2f", (double)x);   /* nano's printf has no floating point */
#endif
    printf("\n");
    free(p);
    return 0;
}
EOF
"${cc[@]}" -mcpu=cortex-m3 -mthumb --specs=nano.specs --specs=rdimon.specs -T "$here/mps2.ld" -Wl,--no-warn-rwx-segments run.c vectors.c -o m3-nano.elf
"${cc[@]}" "${m4h[@]}" --specs=nano.specs --specs=rdimon.specs -T "$here/mps2.ld" -Wl,--no-warn-rwx-segments run.c vectors.c -o m4-nano.elf
"${cc[@]}" "${m4h[@]}" -DFULL --specs=rdimon.specs -T "$here/mps2.ld" -Wl,--no-warn-rwx-segments run.c vectors.c -o m4-full.elf
run mps2-an385 m3-nano.elf "newlib: heap 13.00"
run mps2-an386 m4-nano.elf "newlib: heap 13.00"
run mps2-an386 m4-full.elf "newlib: heap 13.00 3.25"
