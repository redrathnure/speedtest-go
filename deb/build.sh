#!/bin/sh
# Build a Debian package for speedtest-go.
#
#   ./deb/build.sh
#
# Produces deb/build/speedtest-go_<version>_<arch>.deb, where <version> comes
# from `git describe` (a leading "v" is stripped) and <arch> from
# `dpkg --print-architecture` unless DEB_HOST_ARCH is given.
#
# Requirements: a Go toolchain (see go.mod) and dpkg-deb. The binary is built
# with CGO disabled, so cross-building (e.g. DEB_HOST_ARCH=arm64) needs no
# extra cross-compilation toolchain.
set -eu

# Keep the staged tree at the canonical 0755/0644 regardless of the caller's
# umask; dpkg-deb --root-owner-group only rewrites ownership, not modes.
umask 022


SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
BUILD_DIR="$ROOT_DIR/dist"
STAGE_DIR="$ROOT_DIR/build/deb_stage"

# set from outside to change place for rsult deb package(s)
DEST_DIR="${DEST_DIR:-$ROOT_DIR/dist}"

# ── Package metadata ────────────────────────────────────────────────────────
if [ -z "${VERSION:-}" ] && git -C "$ROOT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    VERSION=$(git -C "$ROOT_DIR" describe --tags --always)
fi
VERSION=${VERSION:-0.0.0}
VERSION=$(echo $VERSION | sed 's/^v//')
# A Debian version must start with a digit, a bare commit hash may not.
case "$VERSION" in
    [0-9]*) ;;
    *) VERSION="0.0.0+g$VERSION" ;;
esac

ARCH=${DEB_HOST_ARCH:-$(dpkg --print-architecture)}
MAINTAINER=${MAINTAINER:-speedtest-go packagers <speedtest-go@packages.invalid>}

# dpkg architecture → Go architecture. CGO is disabled, so a Go cross-build
# is all that is needed for foreign architectures.
if [ -z "${GOARCH:-}" ]; then
    case "$ARCH" in
        amd64)   GOARCH=amd64 ;;
        arm64)   GOARCH=arm64 ;;
        armhf)   GOARCH=arm;  GOARM=7 ;;
        armel)   GOARCH=arm;  GOARM=6 ;;
        i386)    GOARCH=386 ;;
        ppc64el) GOARCH=ppc64le ;;
        *)       GOARCH=$(go env GOARCH) ;;
    esac
    export GOARCH
    if [ -n "${GOARM:-}" ]; then
        export GOARM
    fi
fi

# ── Sanity checks ───────────────────────────────────────────────────────────
for script in postinst prerm postrm; do
    sh -n "$SCRIPT_DIR/DEBIAN/$script"
done

# ── Stage the payload ───────────────────────────────────────────────────────
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR/usr/bin"

# The server binary. -buildvcs=false keeps the build working from a source
# tarball as well as from a git checkout.
(cd "$ROOT_DIR" && CGO_ENABLED=0 GOOS=linux go build \
    -ldflags "-w -s" -trimpath -buildvcs=false \
    -o "$STAGE_DIR/usr/bin/speedtest-go" .)
chmod 0755 "$STAGE_DIR/usr/bin/speedtest-go"

install -D -m0644 "$SCRIPT_DIR/speedtest-go.service" \
    "$STAGE_DIR/usr/lib/systemd/system/speedtest-go.service"

# /etc/speedtest-go holds the two conffiles (see DEBIAN/conffiles).
install -D -m0644 "$SCRIPT_DIR/settings.toml" \
    "$STAGE_DIR/etc/speedtest-go/settings.toml"
install -D -m0644 "$ROOT_DIR/server-list.json" \
    "$STAGE_DIR/etc/speedtest-go/server-list.json"

# Web assets: a minimal set, i.e. everything except the example-*.html demo
# pages. The front end fetches server-list.json relative to the page URL, so
# expose the /etc conffile through the assets directory instead of shipping a
# second copy that could drift out of sync.
ASSETS_SRC="$ROOT_DIR/web/assets"
ASSETS_DST="$STAGE_DIR/usr/share/speedtest-go/assets"
mkdir -p "$ASSETS_DST"
for entry in "$ASSETS_SRC"/*; do
    [ -e "$entry" ] || continue
    case "${entry##*/}" in
        #Keep in sync with build_pkgs::ASSETS_DEFAULT_EXCLUDES
        example-*.html) continue ;;
        index-modern.html*) continue ;;
    esac
    cp -a "$entry" "$ASSETS_DST/"
done
# Web assets are served read-only; normalise the modes the sources carry
# (some are executable in the repository for historical reasons).
find "$ASSETS_DST" -type d -exec chmod 0755 {} +
find "$ASSETS_DST" -type f -exec chmod 0644 {} +
ln -s /etc/speedtest-go/server-list.json "$ASSETS_DST/server-list.json"

# /var/lib/speedtest-go (bolt database, ID-obfuscation salt) is created by
# DEBIAN/postinst rather than shipped as an empty directory, so that dpkg -V
# does not report an ownership mismatch after the service account is applied.

# ── Package metadata ────────────────────────────────────────────────────────
# Installed-Size is in KiB and covers the payload only (DEBIAN/ is added next).
SIZE=$(du -sk "$STAGE_DIR" | cut -f1)

install -d -m0755 "$STAGE_DIR/DEBIAN"
install -m0755 "$SCRIPT_DIR/DEBIAN/postinst" "$STAGE_DIR/DEBIAN/postinst"
install -m0755 "$SCRIPT_DIR/DEBIAN/prerm"    "$STAGE_DIR/DEBIAN/prerm"
install -m0755 "$SCRIPT_DIR/DEBIAN/postrm"   "$STAGE_DIR/DEBIAN/postrm"
install -m0644 "$SCRIPT_DIR/DEBIAN/conffiles" "$STAGE_DIR/DEBIAN/conffiles"

# Substitute the @PLACEHOLDER@ values of the control template. The values are
# escaped for sed's replacement syntax so that an arbitrary MAINTAINER cannot
# break the rendering.
sed_escape() {
    printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'
}
sed -e "s|@VERSION@|$(sed_escape "$VERSION")|g" \
    -e "s|@ARCH@|$(sed_escape "$ARCH")|g" \
    -e "s|@MAINTAINER@|$(sed_escape "$MAINTAINER")|g" \
    -e "s|@SIZE@|$(sed_escape "$SIZE")|g" \
    "$SCRIPT_DIR/DEBIAN/control.in" > "$STAGE_DIR/DEBIAN/control"
chmod 0644 "$STAGE_DIR/DEBIAN/control"

# ── Build ───────────────────────────────────────────────────────────────────
mkdir -p "$DEST_DIR"

DEB_FILE="$DEST_DIR/speedtest-go_${VERSION}_${ARCH}.deb"

rm -f "$DEB_FILE"
dpkg-deb --build --root-owner-group "$STAGE_DIR" "$DEB_FILE"

echo
echo "Built $DEB_FILE"
dpkg-deb --info "$DEB_FILE"
echo "--- contents ---"
dpkg-deb --contents "$DEB_FILE"

if command -v lintian >/dev/null 2>&1; then
    echo "--- lintian ---"
    lintian "$DEB_FILE" || true
fi
