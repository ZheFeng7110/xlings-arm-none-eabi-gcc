# Sourced by the checks of the arm-none-eabi C/C++ library packages
# (newlib-arm-none-eabi.sh, libstdcxx-newlib-arm-none-eabi.sh); not a check itself.
#
# Expects: p (the payload), t (a scratch directory), die. Sets:
#   here      this directory (mps2.ld is here)
#   gcc       the compiler's prefix: ARM_NONE_EABI_GCC, or the one
#             fromsource:arm-none-eabi-gcc in FROMSOURCE_XPKGS (the store of the
#             xlings home tools/fromsource.sh built the package in)
#   root      the payload's sysroot, <p>/arm-none-eabi
#   cc, cxx   the compiler's drivers with --sysroot=<root>
#   multilibs the compiler's multilib directories, one per line
# and defines took(), run().
# shellcheck shell=bash disable=SC2034,SC2154
# (SC2034: what it sets is for the check that sources it; SC2154: p, t, die are that check's.)

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gcc="${ARM_NONE_EABI_GCC:-}"
if [[ -z "$gcc" ]]; then
    [[ -n "${FROMSOURCE_XPKGS:-}" ]] || die "no compiler: set ARM_NONE_EABI_GCC=<its prefix> (tools/fromsource.sh sets FROMSOURCE_XPKGS)"
    found=("$FROMSOURCE_XPKGS"/fromsource-x-arm-none-eabi-gcc/*/)
    [[ ${#found[@]} -eq 1 && -d "${found[0]}" ]] || die "expected one fromsource:arm-none-eabi-gcc in $FROMSOURCE_XPKGS, found: ${found[*]}"
    gcc="${found[0]%/}"
fi
[[ -x "$gcc/bin/arm-none-eabi-gcc" ]] || die "no bin/arm-none-eabi-gcc in $gcc"
root="$p/arm-none-eabi"
[[ -d "$root/include" && -d "$root/lib" ]] || die "no sysroot (arm-none-eabi/include, arm-none-eabi/lib) in $p"
cc=("$gcc/bin/arm-none-eabi-gcc" --sysroot="$root")
cxx=("$gcc/bin/arm-none-eabi-g++" --sysroot="$root")
readelf="$gcc/bin/arm-none-eabi-readelf"
nm="$gcc/bin/arm-none-eabi-nm"
multilibs="$("$gcc/bin/arm-none-eabi-gcc" -print-multi-lib | sed 's/;.*//')"
[[ "$(wc -l <<<"$multilibs")" -eq 29 ]] || die "the compiler at $gcc does not have the 29 rmprofile multilibs"

# took <archive under the sysroot's lib/> <driver> <args...>: a link with those
# arguments takes that archive. A library in the wrong multilib directory links
# cleanly and is wrong only at run time, so the trace is what is checked.
took() {
    local want="$1"; shift
    "$@" -o "$t/took.elf" -Wl,-t > "$t/trace" 2>&1 || { cat "$t/trace" >&2; die "link failed: $*"; }
    grep -qF "$root/lib/$want" "$t/trace" || { grep -E '\.a\b' "$t/trace" | sed 's/(.*//' | sort -u >&2; die "$* did not link lib/$want"; }
}

# run <machine> <elf> <expected line>: semihosting, on qemu's MPS2 boards
# (mps2-an385: Cortex-M3; mps2-an386: Cortex-M4 with FPU).
qemu="$(command -v qemu-system-arm || true)"
[[ -n "$qemu" ]] || die "no qemu-system-arm on PATH: the check declares '# needs: xim:qemu-arm@...', which tools/fromsource.sh installs"
run() {
    local machine="$1" elf="$2" want="$3" out
    out="$(timeout 60 "$qemu" -M "$machine" -nographic -monitor none -serial none \
        -semihosting-config enable=on,target=native -kernel "$elf" 2>&1)" \
        || { printf '%s\n' "$out" >&2; die "$machine: $(basename "$elf") failed or timed out"; }
    grep -qxF "$want" <<<"$out" || { printf '%s\n' "$out" >&2; die "$machine: $(basename "$elf") did not print '$want'"; }
}

# The reset handler of the run checks' programs: enable the FPU (CPACR CP10/CP11;
# write-ignored where there is none), which crt0 does not do on M profile, then
# newlib's _start. Vector 0 is the initial stack (the top of mps2.ld's RAM).
cat > "$t/vectors.c" <<'EOF'
extern void _start(void);
__attribute__((naked)) static void reset(void)
{
    __asm volatile("ldr r0, =0xE000ED88\n"
                   "ldr r1, [r0]\n"
                   "orr r1, r1, #0xF00000\n"
                   "str r1, [r0]\n"
                   "dsb\n"
                   "isb\n"
                   "b _start\n");
}
__attribute__((section(".vectors"), used))
static void (*const vectors[])(void) = { (void (*)(void))0x00400000, reset };
EOF
