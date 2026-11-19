#!/usr/bin/env bash
# Build a fromsource package with xlings and turn what it installed into an
# xlings-res payload an xim recipe can point at.
#
#   tools/fromsource.sh [--data] <name> <version> <out>
#
#   --data   target code / data, the same for every host: one archive named
#            <name>-<version>.tar.gz (otherwise <name>-<version>-linux-<arch>.tar.gz)
#
# Steps: a pinned xlings in a fresh XLINGS_HOME, this repository's fromsource/ as
# the `fromsource` index, `xlings install fromsource:<name>@<version>`, then the
# installed tree is copied out, checked (tools/checks/<name>.sh, run on the copy,
# so relocation is exercised), normalized (host ELFs get the system loader and no
# RPATH: xim's install-time elfpatch binds them to xim:glibc), scanned for the
# build home, and packed reproducibly with a .sha256 and README.provenance.
#
# Where it runs (FROMSOURCE_MODE):
#   container  (default when docker is on PATH) a pinned Debian image; the image
#              supplies only the host tools the recipes expect (m4, perl, tar,
#              bzip2, xz, wget); compilers, glibc and binutils come from xlings.
#   host       this machine, with a scrubbed environment: PATH is xlings' own,
#              /usr/bin:/bin and FROMSOURCE_HOST_TOOLS (a directory of extra tools).
#
# Other knobs:
#   XLINGS_VERSION     the xlings client release to build with
#   FROMSOURCE_HOME    reuse this XLINGS_HOME instead of a fresh one (host mode;
#                      for iterating locally -- provenance says so)
#   FROMSOURCE_WORK    the build directory on a host (must be absent or empty, and
#                      is removed afterwards); the same one gives the same bytes
#   FROMSOURCE_ALLOW_NEEDED  extra sonames host ELFs may need, space-separated
set -euo pipefail

XLINGS_VERSION="${XLINGS_VERSION:-2026.11.16.1}"
# The factory image, pinned by digest (the one xim-pkgindex tools/res/build.sh uses).
DEBIAN="debian:12@sha256:2c037a04925515fdd6ea85ea14a682d0e79931f5e9f5d07b6dbfc6ba12f9e858"
HOST_PKGS="ca-certificates curl wget xz-utils bzip2 m4 perl"

log() { printf '[fromsource] %s\n' "$*" >&2; }
die() { log "$*"; exit 1; }

kind=binary
[[ "${1:-}" == --data ]] && { kind=data; shift; }
[[ $# -eq 3 ]] || die "usage: $0 [--data] <name> <version> <out>"
name="$1"; version="$2"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$3"; out="$(cd "$3" && pwd)"
arch="$(uname -m)"; [[ "$arch" == arm64 ]] && arch=aarch64

mode="${FROMSOURCE_MODE:-}"
if [[ -z "$mode" ]]; then
    if command -v docker >/dev/null; then mode=container; else mode=host; fi
fi

# --- container: re-run this script inside the pinned image ------------------
if [[ "$mode" == container ]]; then
    commit="$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo unknown)"
    [[ -z "$(git -C "$repo" status --porcelain 2>/dev/null)" ]] || commit="$commit-dirty"
    log "$name $version in $DEBIAN"
    docker run --rm -v "$repo:/src:ro" -v "$out:/out" -e DEBIAN_FRONTEND=noninteractive \
        -e FROMSOURCE_MODE=inner -e FROMSOURCE_COMMIT="$commit" -e XLINGS_VERSION \
        -e FROMSOURCE_ALLOW_NEEDED "$DEBIAN" bash -euo pipefail -c "
            trap 'chown -R $(id -u):$(id -g) /out' EXIT
            apt-get -qq update && apt-get -qq install -y --no-install-recommends $HOST_PKGS >/dev/null
            bash /src/tools/fromsource.sh $([[ $kind == data ]] && echo --data) '$name' '$version' /out"
    exit 0
fi

[[ "$mode" == host || "$mode" == inner ]] || die "FROMSOURCE_MODE: container, host (got $mode)"
commit="${FROMSOURCE_COMMIT:-$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo unknown)}"
if [[ "$mode" == host && -z "${FROMSOURCE_COMMIT:-}" && -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]]; then
    commit="$commit-dirty"
fi

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
trap 'rm -rf "$work"' EXIT

# --- xlings, pinned, in its own home -----------------------------------------
reused=""
if [[ -n "${FROMSOURCE_HOME:-}" ]]; then
    [[ "$mode" == host ]] || die "FROMSOURCE_HOME is for host mode"
    home="$FROMSOURCE_HOME"; reused=" (reused home, not a fresh one)"
    [[ -x "$home/bin/xlings" ]] || die "FROMSOURCE_HOME=$home has no bin/xlings"
else
    home="$work/home"
    xl="xlings-$XLINGS_VERSION-linux-$arch"
    base="https://github.com/openxlings/xlings/releases/download/v$XLINGS_VERSION"
    curl -fsSL --retry 3 --retry-all-errors -o "$work/$xl.tar.gz" "$base/$xl.tar.gz"
    curl -fsSL --retry 3 --retry-all-errors -o "$work/$xl.tar.gz.sha256" "$base/$xl.tar.gz.sha256"
    (cd "$work" && sha256sum -c "$xl.tar.gz.sha256" >/dev/null) || die "xlings $XLINGS_VERSION does not match its digest"
    tar -xzf "$work/$xl.tar.gz" -C "$work"
fi

# Every xlings call sees only this: no outer XLINGS_*, no outer toolchains.
host_path="/usr/bin:/bin"
[[ -n "${FROMSOURCE_HOST_TOOLS:-}" ]] && host_path="$FROMSOURCE_HOST_TOOLS:$host_path"
xlings() {
    env -i HOME="${HOME:-/root}" USER="${USER:-root}" TERM=dumb LANG=C.UTF-8 \
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
log "xlings $XLINGS_VERSION: install fromsource:$name@$version ($mode mode$reused)"
if ! xlings install -y --agent "fromsource:$name@$version" >"$work/install.log" 2>&1; then
    cat "$work/install.log" >&2
    for f in "$home"/logs/hooks/fromsource-*.install.log; do
        [[ -f "$f" ]] && { log "--- $(basename "$f")"; tail -80 "$f" >&2; }
    done
    die "xlings install fromsource:$name@$version failed"
fi
installed="$home/data/xpkgs/fromsource-x-$name/$version"
[[ -d "$installed" ]] || die "nothing installed at $installed"

# Host binutils and patchelf, from the same home (xim payloads, not the host's).
tool() {
    local t; t="$(ls -d "$home"/data/xpkgs/xim-x-"$1"/*/bin/"$2" 2>/dev/null | sort -V | tail -1)"
    [[ -x "$t" ]] || die "no $2 from xim:$1 in $home"
    printf '%s' "$t"
}
readelf="$(tool binutils readelf)"
patchelf="$(tool patchelf patchelf)"

# --- the payload: a copy, checked where it now lives --------------------------
if [[ "$kind" == data ]]; then d="$name-$version"; file="$name-$version.tar.gz"
else d="$name-$version-linux-$arch"; file="$name-$version-linux-$arch.tar.gz"; fi
payload="$work/$d"
cp -a "$installed" "$payload"

check="$repo/tools/checks/$name.sh"
if [[ -f "$check" ]]; then
    log "checks: tools/checks/$name.sh"
    # The copy still has xlings' INTERP/RPATH, so its programs run here.
    READELF="$readelf" bash "$check" "$payload" "$version" || die "tools/checks/$name.sh failed"
else
    log "no tools/checks/$name.sh: only the generic checks run"
fi

# --- normalize ------------------------------------------------------------------
case "$arch" in
    x86_64)  loader=/lib64/ld-linux-x86-64.so.2; machine="X86-64" ;;
    aarch64) loader=/lib/ld-linux-aarch64.so.1;  machine="AArch64" ;;
    *) die "unsupported host architecture $arch" ;;
esac
allowed=" libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 librt.so.1 ld-linux-x86-64.so.2 ld-linux-aarch64.so.1 ${FROMSOURCE_ALLOW_NEEDED:-} "

# xlings' own record of how this install resolved, not part of the package.
rm -f "$payload/.xlings-resolution.json"
find "$payload" -name '*.la' -delete
glibc_max=""
host_elfs=0
: > "$work/host-elfs"
while IFS= read -r -d '' f; do
    [[ "$(head -c4 "$f" | od -An -c | tr -d ' ')" == '177ELF' ]] || continue
    hdr="$("$readelf" -hW "$f" 2>/dev/null)" || continue
    # Only this host's executables and shared objects; target code is left alone.
    grep -q "Machine:.*$machine" <<<"$hdr" || continue
    grep -Eq 'Type:[[:space:]]+(EXEC|DYN)' <<<"$hdr" || continue
    printf '%s\n' "$f" >> "$work/host-elfs"
    dyn="$("$readelf" -dW "$f" 2>/dev/null)"
    grep -q '(NEEDED)' <<<"$dyn" || continue
    host_elfs=$((host_elfs + 1))
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
log "host ELFs normalized: $host_elfs (INTERP $loader, no RPATH; glibc symbols up to ${glibc_max:-none})"
[[ "$kind" == data || "$host_elfs" -gt 0 ]] || die "a binary payload with no host ELF: is this --data?"

# The build home must not survive anywhere but in a host program: in a text file
# (a .pc, a .la, a specs file) it is a path that exists on nobody's machine, and
# in target code (the debug info of a .a/.o) it is that and a payload that differs
# with the directory it was built in. In a host program it is the configured
# prefix (GCC's, binutils'), which the program relocates from where it runs.
naming="$(grep -rlaF "$home" "$payload" | sort || true)"
leaks="$(comm -23 <(sed '/^$/d' <<<"$naming") <(sort "$work/host-elfs"))"
[[ -z "$leaks" ]] || die "the build home ($home) is in: $(sed "s|^$payload/||" <<<"$leaks" | head -20 | tr '\n' ' ')"
log "host programs naming the configured prefix (relocated at run time): $(sed '/^$/d' <<<"$naming" | wc -l)"

# --- provenance and the archive ----------------------------------------------
recipe="$(ls "$repo"/fromsource/pkgs/*/"$name".lua)"
deps="$(xlings info "fromsource:$name@$version" --agent 2>/dev/null | grep -E 'deps:' | sed 's/^ *//' | tr '\n' ';' || true)"
cat > "$payload/README.provenance" <<EOF
$name $version, built from source by xlings $XLINGS_VERSION as fromsource:$name@$version
recipe: fromsource/pkgs/${recipe#$repo/fromsource/pkgs/} (sha256 $(sha256sum "$recipe" | cut -d' ' -f1)) at $commit of https://github.com/ZheFeng7110/xlings-arm-none-eabi-gcc
dependencies: $deps
factory: $([[ "$mode" == inner ]] && echo "$DEBIAN, host tools: $HOST_PKGS" || echo "host mode on $(uname -srm)$reused")
normalized by tools/fromsource.sh: host ELFs' INTERP set to $loader, RPATH removed (xim's elfpatch binds them at install); glibc symbol versions up to ${glibc_max:-none}
EOF

tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner --hard-dereference \
    -cf - -C "$work" "$d" | gzip -n -9 > "$out/$file"
(cd "$out" && sha256sum "$file" > "$file.sha256")
log "$(cat "$out/$file.sha256")"
