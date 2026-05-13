#!/bin/sh
# esp-emu installer / updater (GitHub Releases edition)
#
# Usage (one-liner):
#   curl -fsSL https://raw.githubusercontent.com/mahavirj/esp-emulator/main/install.sh | sh
#
# Usage (with options):
#   curl -fsSL https://.../install.sh | sh -s -- --version 0.29.0
#   curl -fsSL https://.../install.sh | sh -s -- --bin-dir ~/bin
#   curl -fsSL https://.../install.sh | sh -s -- --check
#
# Or save and run:
#   curl -fsSLO https://.../install.sh && sh install.sh [opts]
#
# Drops the esp-emu binary at $HOME/.local/bin/esp-emu by default. The tarball
# contains only the binary; docs and helper scripts live alongside install.sh
# in the public release mirror at github.com/mahavirj/esp-emulator.
#
# Requires: curl, tar, sha256sum (or shasum -a 256). No JSON parser needed —
# the latest version is resolved via GitHub's /releases/latest → /releases/tag/vX
# web redirect using `curl -w '%{url_effective}'`.

set -eu

DEFAULT_REPO="mahavirj/esp-emulator"
REPO="${ESP_EMU_REPO:-$DEFAULT_REPO}"
BIN_DIR="${ESP_EMU_BIN_DIR:-$HOME/.local/bin}"

# Hidden hook for local testing (point at a localhost mirror). Not exposed
# via --help; see header comments.
DL_BASE="${ESP_EMU_DL_BASE:-https://github.com}"
VERSION=""
CHECK_ONLY=false
FORCE=false
QUIET=false

usage() {
    cat <<EOF
Usage: install.sh [OPTIONS]

Install or update esp-emu (RISC-V emulator for ESP32-C3/C6/P4/S31).

Options:
  --version X.Y.Z     Install a specific version (default: latest GitHub release)
  --bin-dir DIR       Install location for the binary (default: \$HOME/.local/bin)
  --repo OWNER/NAME   GitHub repository hosting the releases (default: $DEFAULT_REPO)
  --check             Print latest version and exit (no install)
  --force             Reinstall even if same version already present
  --quiet             Suppress informational output
  -h, --help          Show this help

Environment:
  ESP_EMU_REPO        Same as --repo
  ESP_EMU_BIN_DIR     Same as --bin-dir

Self-update from an installed binary:
  esp-emu update

EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version)        VERSION="${2:?--version needs an argument}"; shift 2 ;;
        --version=*)      VERSION="${1#*=}"; shift ;;
        --bin-dir)        BIN_DIR="${2:?--bin-dir needs an argument}"; shift 2 ;;
        --bin-dir=*)      BIN_DIR="${1#*=}"; shift ;;
        --repo)           REPO="${2:?--repo needs an argument}"; shift 2 ;;
        --repo=*)         REPO="${1#*=}"; shift ;;
        --check)          CHECK_ONLY=true; shift ;;
        --force)          FORCE=true; shift ;;
        --quiet)          QUIET=true; shift ;;
        -h|--help)        usage; exit 0 ;;
        *) printf 'install.sh: unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

# ── output helpers ──────────────────────────────────────────────────────
_use_color=true
[ -n "${NO_COLOR:-}" ] && _use_color=false
[ -t 2 ] || _use_color=false
if [ "$_use_color" = true ]; then
    _red='\033[31m'; _yel='\033[33m'; _grn='\033[32m'; _bld='\033[1m'; _rst='\033[0m'
else
    _red=''; _yel=''; _grn=''; _bld=''; _rst=''
fi

say()  { [ "$QUIET" = true ] || printf '%s\n' "$*"; }
ok()   { [ "$QUIET" = true ] || printf '%b%s%b %s\n' "$_grn" "ok:"    "$_rst" "$*"; }
warn() { printf '%bwarn:%b %s\n' "$_yel" "$_rst" "$*" >&2; }
die()  { printf '%berror:%b %s\n' "$_red" "$_rst" "$*" >&2; exit 1; }

need() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# ── platform detection ──────────────────────────────────────────────────
detect_platform() {
    _os="$(uname -s)"
    _arch="$(uname -m)"
    case "$_os" in
        Linux)
            case "$_arch" in
                x86_64|amd64) printf '%s' 'x86_64-unknown-linux-gnu' ;;
                *) die "unsupported Linux arch: $_arch (only x86_64 has prebuilt binaries; build from source)" ;;
            esac
            ;;
        Darwin)
            case "$_arch" in
                arm64|aarch64) printf '%s' 'aarch64-apple-darwin' ;;
                x86_64) die "macOS x86_64 prebuilt is not published. Build from source." ;;
                *) die "unsupported macOS arch: $_arch" ;;
            esac
            ;;
        MINGW*|MSYS*|CYGWIN*)
            die "Windows is not supported by install.sh. Build from source under WSL or native Windows."
            ;;
        *) die "unsupported OS: $_os" ;;
    esac
}

# ── sha256 ──────────────────────────────────────────────────────────────
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        die "no sha256 tool found (sha256sum or shasum)"
    fi
}

# Resolve the latest released version from GitHub's web redirect.
#   $DL_BASE/$REPO/releases/latest  →  302  →  $DL_BASE/$REPO/releases/tag/vX.Y.Z
# We follow the redirect chain with -L, discard the body via -o /dev/null,
# and read the final URL out of curl's -w '%{url_effective}'. No API rate
# limit, no JSON, no python.
resolve_latest_version() {
    final="$(curl -fsSL -o /dev/null -w '%{url_effective}' \
        "$DL_BASE/$REPO/releases/latest" 2>/dev/null)" \
        || die "failed to query $DL_BASE/$REPO/releases/latest"
    case "$final" in
        */releases/tag/v*) printf '%s' "${final##*/v}" ;;
        */releases/tag/*)
            # Project doesn't use a `v` prefix on tags; take everything after /tag/.
            printf '%s' "${final##*/tag/}"
            ;;
        *) die "unexpected redirect target while resolving latest: $final" ;;
    esac
}

# Look up an asset's sha256 from the published SHA256SUMS file.
# Args: shasums_file, asset_name. Stdout: hex digest (empty if not present).
shasum_lookup() {
    awk -v f="$2" '$2 == f || $2 == "*" f { print $1; exit }' "$1"
}

# ── main ────────────────────────────────────────────────────────────────
need curl
need tar

PLATFORM="$(detect_platform)"
say "Platform: $PLATFORM"
say "Repository: $REPO"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/esp-emu-install.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT INT TERM HUP

if [ -z "$VERSION" ]; then
    say "Resolving latest release via $DL_BASE/$REPO/releases/latest"
    VERSION="$(resolve_latest_version)"
    [ -n "$VERSION" ] || die "could not determine latest version"
fi

TAG="v$VERSION"
ARCHIVE_NAME="esp-emu-${VERSION}-${PLATFORM}.tar.gz"
URL="$DL_BASE/$REPO/releases/download/$TAG/$ARCHIVE_NAME"
SHASUMS_URL="$DL_BASE/$REPO/releases/download/$TAG/SHA256SUMS"

say "Target version: $VERSION"
say "Archive URL:    $URL"

if [ "$CHECK_ONLY" = true ]; then
    say "(--check) exiting without install"
    exit 0
fi

# Skip if already up-to-date.
EXISTING_BIN="$BIN_DIR/esp-emu"
if [ -x "$EXISTING_BIN" ] && [ "$FORCE" != true ]; then
    current="$("$EXISTING_BIN" --version 2>/dev/null | awk 'NR==1 {print $NF}' || true)"
    if [ -n "$current" ] && [ "$current" = "$VERSION" ]; then
        ok "esp-emu $current already installed at $EXISTING_BIN (use --force to reinstall)"
        exit 0
    fi
fi

say "Downloading $ARCHIVE_NAME"
if [ "$QUIET" = true ]; then
    curl -fsSL "$URL" -o "$tmpdir/$ARCHIVE_NAME" || die "download failed: $URL"
else
    curl -fSL --progress-bar "$URL" -o "$tmpdir/$ARCHIVE_NAME" || die "download failed: $URL"
fi

# Pull SHA256SUMS — soft-fail with a warning if absent (older releases may not have one).
EXPECTED=""
if curl -fsSL "$SHASUMS_URL" -o "$tmpdir/SHA256SUMS" 2>/dev/null; then
    EXPECTED="$(shasum_lookup "$tmpdir/SHA256SUMS" "$ARCHIVE_NAME")"
fi
if [ -n "$EXPECTED" ]; then
    got="$(sha256_of "$tmpdir/$ARCHIVE_NAME")"
    [ "$got" = "$EXPECTED" ] || die "sha256 mismatch (expected $EXPECTED, got $got)"
    ok "sha256 verified"
else
    warn "no published SHA256SUMS entry for $ARCHIVE_NAME — relying on TLS"
fi

say "Extracting"
tar -xzf "$tmpdir/$ARCHIVE_NAME" -C "$tmpdir"

# Locate esp-emu inside the extracted tree. Modern (binary-only) layout is
# esp-emu-<ver>-<plat>/esp-emu; legacy archives stash it deeper, so fall back
# to a `find` for safety.
SRC_BIN=""
for cand in \
    "$tmpdir/esp-emu-${VERSION}-${PLATFORM}/esp-emu" \
    "$tmpdir/esp-emu"; do
    if [ -f "$cand" ]; then
        SRC_BIN="$cand"
        break
    fi
done
if [ -z "$SRC_BIN" ]; then
    SRC_BIN="$(find "$tmpdir" -type f -name esp-emu -not -path "*/tools/*" | head -1 || true)"
fi
[ -n "$SRC_BIN" ] && [ -f "$SRC_BIN" ] || die "esp-emu binary not found inside archive"

mkdir -p "$BIN_DIR"

# Atomic install via .new + rename to dodge ETXTBSY on Linux.
NEW_BIN="$BIN_DIR/esp-emu.new"
cp "$SRC_BIN" "$NEW_BIN"
chmod +x "$NEW_BIN"
mv "$NEW_BIN" "$BIN_DIR/esp-emu"

ok "Installed esp-emu $VERSION to $BIN_DIR/esp-emu"

if [ "$QUIET" != true ]; then
    printf '\n'
    case ":${PATH:-}:" in
        *":$BIN_DIR:"*) ;;
        *)
            printf 'Note: %s is not on your PATH.\n' "$BIN_DIR"
            printf 'Add this to your shell profile (~/.bashrc, ~/.zshrc, or ~/.profile):\n\n'
            printf '    %bexport PATH="%s:$PATH"%b\n\n' "$_bld" "$BIN_DIR" "$_rst"
            ;;
    esac
    printf 'Run: %b%s/esp-emu --help%b\n' "$_bld" "$BIN_DIR" "$_rst"
    printf 'Docs and helper scripts: https://github.com/%s\n' "$REPO"
fi
