#!/usr/bin/env bash
# Build a fromsource package with xlings and turn what it installed into an
# xlings-res payload an xim recipe can point at.
#
#   tools/fromsource.sh [--data] [--host windows] [--revision N] <name> <version> <out>
#
#   --data          target code / data, the same for every host: one archive named
#                   <name>-<version>.tar.gz (otherwise <name>-<version>-<os>-<arch>.tar.gz)
#   --revision N    the Nth rebuild of a published version (a fix of ours, the same
#                   upstream source): the payload is <name>-<version>-rN... and its
#                   release <name>-<version>-rN; a published asset never changes
#   --host windows  the Windows payload <name>-<version>-windows-x86_64.zip, from
#                   fromsource:<name>-mingw-cross: a recipe that cross-builds on Linux
#                   (x86_64) what runs on Windows. Its checks run on Windows
#                   (build.yml), not here: nothing in it runs on this machine.
#
# Steps: a pinned xlings in a fresh XLINGS_HOME, this repository's fromsource/ as
# the `fromsource` index, `xlings install fromsource:<name>@<version>`, then the
# installed tree is copied out, checked (tools/checks/<name>.sh, run on the copy,
# so relocation is exercised; a check's `# needs: <ns:pkg@ver>` lines are installed
# by the same xlings first and put on its PATH, and FROMSOURCE_XPKGS names the
# home's package store, where it finds what the package was built with),
# normalized, scanned for the build home, and packed
# reproducibly with a .sha256 and README.provenance. Normalized, per host:
#   linux    host ELFs get the system loader and no RPATH (xim's install-time
#            elfpatch binds them to xim:glibc); they may need glibc alone
#   macosx   Mach-O programs may link only the system's libraries, with no LC_RPATH
#   windows  PE programs may import only Windows' own DLLs, with no build time
#
# Where it runs (FROMSOURCE_MODE):
#   container  (default when docker is on PATH) a pinned Debian image; the image
#              supplies only the host tools the recipes expect (m4, perl, tar,
#              bzip2, xz, wget); compilers, glibc and binutils come from xlings.
#              --host windows uses a Debian 13 image: xim:mingw-cross-gcc needs glibc 2.38.
#   host       this machine, with a scrubbed environment: PATH is xlings' own,
#              /usr/bin:/bin and FROMSOURCE_HOST_TOOLS (a directory of extra tools).
#              On macOS (Apple Silicon) the only mode: Xcode's clang builds there,
#              and packing needs GNU tar (gtar).
#
# Other knobs:
#   XLINGS_VERSION     the xlings client release to build with
#   FROMSOURCE_HOME    reuse this XLINGS_HOME instead of a fresh one (host mode;
#                      for iterating locally -- provenance says so)
#   FROMSOURCE_WORK    the build directory on a host (must be absent or empty, and
#                      is removed afterwards); the same one gives the same bytes
#   FROMSOURCE_KEEP    set: a failed build keeps the build directory (logs, config.log)
#   FROMSOURCE_ALLOW_NEEDED  extra libraries host programs may need, space-separated
#                      (sonames; Mach-O install names; DLL names)
set -euo pipefail

XLINGS_VERSION="${XLINGS_VERSION:-2026.11.16.1}"
# The factory image, pinned by digest (the one xim-pkgindex tools/res/build.sh uses).
DEBIAN="debian:12@sha256:2c037a04925515fdd6ea85ea14a682d0e79931f5e9f5d07b6dbfc6ba12f9e858"
# The Windows cross factory: xim:mingw-cross-gcc runs on the host's glibc (no
# xim:glibc binding) and needs 2.38 (and libzstd.so.1); Debian 12 has 2.36.
DEBIAN_MINGW="debian:13@sha256:9c6e381421d0f48d1b8133e573f33c185ee16cbf505eda9c4a8a4791b25ea8a6"
HOST_PKGS="ca-certificates curl wget xz-utils bzip2 m4 perl"

log() { printf '[fromsource] %s\n' "$*" >&2; }
die() { log "$*"; exit 1; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

kind=binary; target_os=""; revision=""
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --data) kind=data; shift ;;
        --host) target_os="${2:-}"; shift 2 ;;
        --revision) revision="${2:-}"; shift 2
            [[ "$revision" =~ ^[1-9][0-9]*$ ]] || die "--revision: a positive integer (got '$revision')" ;;
        *) die "unknown option $1" ;;
    esac
done
[[ $# -eq 3 ]] || die "usage: $0 [--data] [--host windows] [--revision N] <name> <version> <out>"
rev=""; [[ -n "$revision" ]] && rev="-r$revision"   # in the payload's name
name="$1"; version="$2"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$3"; out="$(cd "$3" && pwd)"
arch="$(uname -m)"; [[ "$arch" == arm64 ]] && arch=aarch64
case "$(uname -s)" in
    Linux) build_os=linux ;;
    Darwin) build_os=macosx ;;
    *) die "unsupported build system $(uname -s)" ;;
esac
[[ -n "$target_os" ]] || target_os="$build_os"
recipe_name="$name"
case "$build_os/$target_os" in
    linux/linux|macosx/macosx) ;;
    linux/windows)
        [[ "$arch" == x86_64 ]] || die "--host windows builds on x86_64 Linux (xim:mingw-cross-gcc)"
        [[ "$kind" == binary ]] || die "--host windows is for host programs, not --data"
        recipe_name="$name-mingw-cross" ;;
    *) die "cannot build for $target_os on $build_os" ;;
esac
[[ "$build_os" == macosx && "$arch" != aarch64 ]] && die "macOS: Apple Silicon only (xlings has no x86_64 macOS client)"

mode="${FROMSOURCE_MODE:-}"
if [[ -z "$mode" ]]; then
    if [[ "$build_os" == linux ]] && command -v docker >/dev/null; then mode=container; else mode=host; fi
fi

# --- container: re-run this script inside the pinned image ------------------
if [[ "$mode" == container ]]; then
    [[ "$build_os" == linux ]] || die "container mode is for Linux"
    commit="$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo unknown)"
    [[ -z "$(git -C "$repo" status --porcelain 2>/dev/null)" ]] || commit="$commit-dirty"
    image="$DEBIAN"; pkgs="$HOST_PKGS"
    [[ "$target_os" == windows ]] && { image="$DEBIAN_MINGW"; pkgs="$pkgs zip"; }
    opts=""; [[ "$kind" == data ]] && opts="--data"; [[ "$target_os" != linux ]] && opts="$opts --host $target_os"
    [[ -n "$revision" ]] && opts="$opts --revision $revision"
    log "$recipe_name $version in $image"
    docker run --rm -v "$repo:/src:ro" -v "$out:/out" -e DEBIAN_FRONTEND=noninteractive \
        -e FROMSOURCE_MODE=inner -e FROMSOURCE_COMMIT="$commit" -e XLINGS_VERSION \
        -e FROMSOURCE_ALLOW_NEEDED -e FROMSOURCE_PKGS="$pkgs" -e FROMSOURCE_IMAGE="$image" "$image" bash -euo pipefail -c "
            trap 'chown -R $(id -u):$(id -g) /out' EXIT
            apt-get -qq update && apt-get -qq install -y --no-install-recommends $pkgs >/dev/null
            bash /src/tools/fromsource.sh $opts '$name' '$version' /out"
    exit 0
fi

[[ "$mode" == host || "$mode" == inner ]] || die "FROMSOURCE_MODE: container, host (got $mode)"
commit="${FROMSOURCE_COMMIT:-$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo unknown)}"
if [[ "$mode" == host && -z "${FROMSOURCE_COMMIT:-}" && -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]]; then
    commit="$commit-dirty"
fi

# The packers, before hours of building: GNU tar (--sort), or zip for Windows.
if [[ "$target_os" == windows ]]; then
    command -v zip >/dev/null || die "a Windows payload is a .zip: no zip on PATH"
elif tar --version 2>/dev/null | grep -q 'GNU tar'; then tar=tar
elif command -v gtar >/dev/null; then tar=gtar
else die "packing needs GNU tar (tar or gtar)"; fi

# The build directory is part of the output: GCC records its configured prefix
# (under XLINGS_HOME) in its programs, and cc1's checksum of its own objects
# covers it. A fixed directory is what makes two builds the same bytes: /w in the
# container; FROMSOURCE_WORK on a host (a fresh mktemp directory otherwise).
if [[ "$mode" == inner ]]; then work=/w
elif [[ -n "${FROMSOURCE_WORK:-}" ]]; then work="$FROMSOURCE_WORK"
else work="$(mktemp -d)"; fi
[[ "$work" == /* && "$work" != / ]] || die "the build directory must be an absolute path other than /: $work"
[[ ! -e "$work" || -z "$(ls -A "$work")" ]] || die "the build directory $work exists and is not empty"
mkdir -p "$work"
# FROMSOURCE_KEEP=1: a failed build leaves the directory, for its logs.
cleanup() {
    local s=$?
    if [[ $s -ne 0 && -n "${FROMSOURCE_KEEP:-}" ]]; then log "kept $work"; else rm -rf "$work"; fi
}
trap cleanup EXIT

# --- xlings, pinned, in its own home -----------------------------------------
reused=""
if [[ -n "${FROMSOURCE_HOME:-}" ]]; then
    [[ "$mode" == host ]] || die "FROMSOURCE_HOME is for host mode"
    home="$FROMSOURCE_HOME"; reused=" (reused home, not a fresh one)"
    [[ -x "$home/bin/xlings" ]] || die "FROMSOURCE_HOME=$home has no bin/xlings"
else
    home="$work/home"
    if [[ "$build_os" == macosx ]]; then xl="xlings-$XLINGS_VERSION-macosx-arm64"
    else xl="xlings-$XLINGS_VERSION-linux-$arch"; fi
    base="https://github.com/openxlings/xlings/releases/download/v$XLINGS_VERSION"
    curl -fsSL --retry 3 --retry-all-errors -o "$work/$xl.tar.gz" "$base/$xl.tar.gz"
    curl -fsSL --retry 3 --retry-all-errors -o "$work/$xl.tar.gz.sha256" "$base/$xl.tar.gz.sha256"
    (cd "$work" && sha256 -c "$xl.tar.gz.sha256" >/dev/null) || die "xlings $XLINGS_VERSION does not match its digest"
    tar -xzf "$work/$xl.tar.gz" -C "$work"
fi

# Every xlings call sees only this: no outer XLINGS_*, no outer toolchains.
host_path="/usr/bin:/bin"
[[ -n "${FROMSOURCE_HOST_TOOLS:-}" ]] && host_path="$FROMSOURCE_HOST_TOOLS:$host_path"
lang=C.UTF-8; [[ "$build_os" == macosx ]] && lang=en_US.UTF-8   # macOS has no C.UTF-8
xlings() {
    env -i HOME="${HOME:-/root}" USER="${USER:-root}" TERM=dumb LANG="$lang" \
        XLINGS_HOME="$home" XLINGS_NON_INTERACTIVE=1 PATH="$home/bin:$host_path" \
        "$home/bin/xlings" "$@" </dev/null
}

if [[ -z "$reused" ]]; then
    (cd "$work/$xl" && env -i HOME="${HOME:-/root}" TERM=dumb XLINGS_HOME="$home" \
        PATH="/usr/bin:/bin" ./bin/xlings self install </dev/null >"$work/xlings-install.log" 2>&1) \
        || { cat "$work/xlings-install.log" >&2; die "xlings self install failed"; }
fi
# A copy of the index: xlings writes its cache into an index directory, and the
# checkout is read-only in the container (and not ours to write on a host).
mkdir -p "$work/index" && cp -a "$repo/fromsource/pkgs" "$work/index/"
xlings config --index-repo "fromsource:$work/index" >/dev/null
xlings update >"$work/update.log" 2>&1 || { cat "$work/update.log" >&2; die "xlings update failed"; }

# --- the build: an ordinary fromsource install --------------------------------
log "xlings $XLINGS_VERSION: install fromsource:$recipe_name@$version ($mode mode$reused)"
if ! xlings install -y --agent "fromsource:$recipe_name@$version" >"$work/install.log" 2>&1; then
    cat "$work/install.log" >&2
    for f in "$home"/logs/hooks/fromsource-*.install.log; do
        [[ -f "$f" ]] && { log "--- $(basename "$f")"; tail -80 "$f" >&2; }
    done
    die "xlings install fromsource:$recipe_name@$version failed"
fi
installed="$home/data/xpkgs/fromsource-x-$recipe_name/$version"
[[ -d "$installed" ]] || die "nothing installed at $installed"

# Host binutils, patchelf, the mingw objdump: from the same home (xim payloads,
# not the host's).
tool() {
    local t; t="$(ls -d "$home"/data/xpkgs/xim-x-"$1"/*/bin/"$2" 2>/dev/null | sort -V | tail -1)"
    [[ -x "$t" ]] || die "no $2 from xim:$1 in $home"
    printf '%s' "$t"
}
readelf=""
if [[ "$target_os" == linux ]]; then
    readelf="$(tool binutils readelf)"
    patchelf="$(tool patchelf patchelf)"
fi
[[ "$target_os" == windows ]] && objdump="$(tool mingw-cross-gcc x86_64-w64-mingw32-objdump)"

# --- the payload: a copy, checked where it now lives --------------------------
if [[ "$kind" == data ]]; then d="$name-$version$rev"; file="$d.tar.gz"
elif [[ "$target_os" == windows ]]; then d="$name-$version$rev-windows-x86_64"; file="$d.zip"
else d="$name-$version$rev-$target_os-$arch"; file="$d.tar.gz"; fi
payload="$work/$d"
cp -a "$installed" "$payload"

check="$repo/tools/checks/$name.sh"
needs=""
if [[ "$target_os" != "$build_os" ]]; then
    log "checks: tools/checks/$name.sh runs on $target_os (build.yml), not here"
elif [[ -f "$check" ]]; then
    # What the check runs with (`# needs: xim:qemu-arm@9.2.4-1`): from the index,
    # by this xlings, like everything else the build used.
    needs="$(sed -n 's/^# needs:[[:space:]]*//p' "$check" | tr '\n' ' ' | sed 's/ *$//')"
    check_path=""
    for n in $needs; do
        [[ "$n" =~ ^([a-z0-9_-]+):([A-Za-z0-9._+-]+)@([A-Za-z0-9._+-]+)$ ]] || die "tools/checks/$name.sh: '# needs: $n' is not <ns>:<pkg>@<version>"
        xlings install -y --agent "$n" >"$work/needs.log" 2>&1 || { cat "$work/needs.log" >&2; die "xlings install $n (for the checks) failed"; }
        bin="$home/data/xpkgs/${BASH_REMATCH[1]}-x-${BASH_REMATCH[2]}/${BASH_REMATCH[3]}/bin"
        [[ -d "$bin" ]] || die "$n installed no $bin"
        check_path="$bin:$check_path"
    done
    log "checks: tools/checks/$name.sh${needs:+ (with $needs)}"
    # On Linux the copy still has xlings' INTERP/RPATH, so its programs run here.
    PATH="$check_path$PATH" READELF="$readelf" FROMSOURCE_XPKGS="$home/data/xpkgs" \
        bash "$check" "$payload" "$version" || die "tools/checks/$name.sh failed"
else
    log "no tools/checks/$name.sh: only the generic checks run"
fi

# --- normalize ------------------------------------------------------------------
# What xlings itself keeps in an install directory, not part of the package: the
# payload stamp (.xpkg-install.json), the recipe snapshot (.xpkg.lua), how the
# install resolved (.xlings-resolution.json), hook effects. Shipped, they would
# describe the fromsource install to whoever installs the xim package.
find "$payload" -mindepth 1 -maxdepth 1 \( -name '.xpkg*' -o -name '.xlings*' \) -exec rm -rf {} +
find "$payload" -name '*.la' -delete
extra=" ${FROMSOURCE_ALLOW_NEEDED:-} "
host_bins=0
: > "$work/host-bins"
magic() { head -c4 "$1" | od -An -tx1 | tr -d ' \n'; }

case "$target_os" in
linux)
    case "$arch" in
        x86_64)  loader=/lib64/ld-linux-x86-64.so.2; machine="X86-64" ;;
        aarch64) loader=/lib/ld-linux-aarch64.so.1;  machine="AArch64" ;;
        *) die "unsupported host architecture $arch" ;;
    esac
    allowed=" libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 ld-linux-x86-64.so.2 ld-linux-aarch64.so.1$extra"
    glibc_max=""
    while IFS= read -r -d '' f; do
        [[ "$(magic "$f")" == 7f454c46 ]] || continue
        hdr="$("$readelf" -hW "$f" 2>/dev/null)" || continue
        # Only this host's executables and shared objects; target code is left alone.
        grep -q "Machine:.*$machine" <<<"$hdr" || continue
        grep -Eq 'Type:[[:space:]]+(EXEC|DYN)' <<<"$hdr" || continue
        printf '%s\n' "$f" >> "$work/host-bins"
        dyn="$("$readelf" -dW "$f" 2>/dev/null)"
        grep -q '(NEEDED)' <<<"$dyn" || continue
        host_bins=$((host_bins + 1))
        for lib in $(awk '/\(NEEDED\)/ { gsub(/[\[\]]/, "", $NF); print $NF }' <<<"$dyn"); do
            [[ "$allowed" == *" $lib "* ]] || die "${f#$payload/} needs $lib, which is not glibc"
        done
        if "$readelf" -lW "$f" | grep -q 'Requesting program interpreter'; then
            "$patchelf" --set-interpreter "$loader" "$f"
        fi
        if grep -Eq '\((RPATH|RUNPATH)\)' <<<"$dyn"; then
            "$patchelf" --remove-rpath "$f"
        fi
        v="$("$readelf" -VW "$f" | grep -o 'GLIBC_[0-9][0-9.]*' | sed 's/GLIBC_//' | sort -V | tail -1)"
        [[ -n "$v" ]] && glibc_max="$(printf '%s\n%s\n' "$glibc_max" "$v" | sed '/^$/d' | sort -V | tail -1)"
    done < <(find "$payload" -type f -print0)
    log "host ELFs normalized: $host_bins (INTERP $loader, no RPATH; glibc symbols up to ${glibc_max:-none})"
    normalized="host ELFs' INTERP set to $loader, RPATH removed (xim's elfpatch binds them at install); glibc symbol versions up to ${glibc_max:-none}"
    ;;
macosx)
    # The system's libraries only (/usr/lib: libSystem, libc++, libiconv, libz).
    # A dylib's own install name (otool -D) is not a dependency.
    minos_max=""
    while IFS= read -r -d '' f; do
        [[ "$(magic "$f")" == cffaedfe ]] || continue
        otool -hv "$f" | grep -q ARM64 || continue
        printf '%s\n' "$f" >> "$work/host-bins"
        host_bins=$((host_bins + 1))
        id="$(otool -D "$f" | sed -n 2p)"
        for lib in $(otool -L "$f" | sed 1d | awk '{ print $1 }'); do
            [[ "$lib" == "$id" ]] && continue
            [[ "$lib" == /usr/lib/* || "$lib" == /System/Library/* || "$extra" == *" $lib "* ]] \
                || die "${f#$payload/} links $lib, which is not the system's"
        done
        ! otool -l "$f" | grep -q LC_RPATH || die "${f#$payload/} has an LC_RPATH"
        v="$(otool -l "$f" | awk '/LC_BUILD_VERSION/ { b = 1 } b && $1 == "minos" { print $2; exit }')"
        [[ -n "$v" ]] && minos_max="$(printf '%s\n%s\n' "$minos_max" "$v" | sed '/^$/d' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
    done < <(find "$payload" -type f -print0)
    log "host Mach-O programs checked: $host_bins (system libraries only, no LC_RPATH; macOS ${minos_max:-?} and later)"
    normalized="host Mach-O programs link only system libraries, no LC_RPATH; built for macOS ${minos_max:-?} and later"
    ;;
windows)
    # Windows' own DLLs only: no libgcc, libstdc++ or winpthread DLL beside them.
    allowed=" kernel32.dll msvcrt.dll advapi32.dll user32.dll shell32.dll ole32.dll ws2_32.dll bcrypt.dll psapi.dll $(tr '[:upper:]' '[:lower:]' <<<"$extra") "
    while IFS= read -r -d '' f; do
        [[ "$(magic "$f")" == 4d5a* ]] || continue
        pe="$(TZ=UTC0 "$objdump" -p "$f" 2>/dev/null)" || continue   # TZ: Time/Date in UTC
        grep -q 'pei-x86-64' <<<"$pe" || continue
        printf '%s\n' "$f" >> "$work/host-bins"
        host_bins=$((host_bins + 1))
        for dll in $(awk '/DLL Name:/ { print tolower($NF) }' <<<"$pe"); do
            [[ "$allowed" == *" $dll "* || "$dll" == api-ms-win-* ]] \
                || die "${f#$payload/} imports $dll, which is not Windows' own"
        done
        grep -Eq '^Time/Date[[:space:]].* 1970$' <<<"$pe" || die "${f#$payload/} records a build time: $(grep '^Time/Date' <<<"$pe")"
    done < <(find "$payload" -type f -print0)
    log "host PE programs checked: $host_bins (Windows DLLs only, no timestamp)"
    normalized="host PE programs import only Windows' own DLLs and record no build time"
    ;;
esac
[[ "$kind" == data || "$host_bins" -gt 0 ]] || die "a binary payload with no host program: is this --data?"
[[ "$kind" == data && "$host_bins" -eq 0 ]] && normalized="no host programs (target code only)"

# The build home must not survive anywhere but in a host program: in a text file
# (a .pc, a .la, a specs file) it is a path that exists on nobody's machine, and
# in target code (the debug info of a .a/.o) it is that and a payload that differs
# with the directory it was built in. In a host program it is the configured
# prefix (GCC's, binutils'), which the program relocates from where it runs.
naming="$(grep -rlaF "$home" "$payload" | sort || true)"
leaks="$(comm -23 <(sed '/^$/d' <<<"$naming") <(sort "$work/host-bins"))"
[[ -z "$leaks" ]] || die "the build home ($home) is in: $(sed "s|^$payload/||" <<<"$leaks" | head -20 | tr '\n' ' ')"
log "host programs naming the configured prefix (relocated at run time): $(sed '/^$/d' <<<"$naming" | wc -l | tr -d ' ')"

# --- provenance and the archive ----------------------------------------------
recipe="$(ls "$repo"/fromsource/pkgs/*/"$recipe_name".lua)"
deps="$(xlings info "fromsource:$recipe_name@$version" --agent 2>/dev/null | grep -E 'deps:' | sed 's/^ *//' | tr '\n' ';' || true)"
if [[ "$mode" == inner ]]; then factory="${FROMSOURCE_IMAGE:-$DEBIAN}, host tools: ${FROMSOURCE_PKGS:-$HOST_PKGS}"
elif [[ "$build_os" == macosx ]]; then
    factory="host mode on $(sw_vers -productName) $(sw_vers -productVersion) $(uname -m), $(xcrun clang --version | head -1), SDK $(xcrun --show-sdk-version)$reused"
else factory="host mode on $(uname -srm)$reused"; fi
built_by="xlings $XLINGS_VERSION as fromsource:$recipe_name@$version"
what="$name $version"; [[ -n "$revision" ]] && what="$what revision $revision"
[[ "$target_os" != "$build_os" ]] && built_by="$built_by (cross-built on $build_os $arch for $target_os)"
cat > "$payload/README.provenance" <<EOF
$what, built from source by $built_by
recipe: fromsource/pkgs/${recipe#$repo/fromsource/pkgs/} (sha256 $(sha256 "$recipe" | cut -d' ' -f1)) at $commit of https://github.com/ZheFeng7110/xlings-arm-none-eabi-gcc
dependencies: $deps
factory: $factory
normalized by tools/fromsource.sh: $normalized
checked by: $(if [[ "$target_os" != "$build_os" ]]; then echo "tools/checks/$name.sh on $target_os (build.yml)"
              elif [[ -f "$check" ]]; then echo "tools/checks/$name.sh${needs:+, with $needs}"; else echo "the generic checks only"; fi)
EOF

if [[ "$target_os" == windows ]]; then
    # zip records local DOS times, so the zone is fixed with them; -X: no uid/gid
    # or extra timestamps; -D: no directory entries; links are stored as files.
    find "$payload" -exec env TZ=UTC0 touch -h -t 198001010000 {} +
    (cd "$work" && find "$d" \( -type f -o -type l \) | LC_ALL=C sort \
        | TZ=UTC0 zip -X -D -q -9 -@ "$out/$file")
else
    "$tar" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --hard-dereference \
        -cf - -C "$work" "$d" | gzip -n -9 > "$out/$file"
fi
(cd "$out" && sha256 "$file" > "$file.sha256")
log "$(cat "$out/$file.sha256")"
