#!/bin/bash
#
# Builds the installer package (ticket 09).
#
# A per-user package: everything lands under the installing user's home, no
# administrator password is asked for, and nothing is owned by root. Install it
# with
#
#     installer -pkg build/Issues-<version>.pkg -target CurrentUserHomeDirectory
#
# or by double-clicking, which is what most people will do.
#
# Signing is opt-in. Set PKG_SIGN_IDENTITY to the name of a "Developer ID
# Installer" certificate to produce something that installs on another Mac without
# a Gatekeeper detour; unsigned is the default because that certificate requires a
# paid account, and an unsigned package still installs fine from the terminal or
# via right-click, Open.
set -euo pipefail

cd "$(dirname "$0")/.."
BUILD="build"
STAGE="$BUILD/stage"
COMPONENT="$BUILD/component"

rm -rf "$BUILD"
mkdir -p "$STAGE/.local/bin" "$COMPONENT"

# Every product, not just the server. `swift build --product X` does not rebuild
# the others, which has already shipped a stale binary into a smoke test once.
echo "Building release binaries…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)"

# The CLI and the MCP server travel with the server, as ticket 12 expects: the MCP
# executable is part of the distribution but is launched by its host, never by
# launchd, so it gets no agent of its own.
for product in issues-server issues issues-mcp; do
    cp "$BIN/$product" "$STAGE/.local/bin/$product"
done

VERSION="$("$STAGE/.local/bin/issues-server" version)"
echo "Packaging version $VERSION"

# Payload paths are relative to the install destination, which for a home-directory
# install is the user's home: `.local/bin/issues-server` becomes
# ~/.local/bin/issues-server.
pkgbuild \
    --root "$STAGE" \
    --identifier co.trywe.issues.server \
    --version "$VERSION" \
    --scripts Scripts/pkg/scripts \
    --install-location / \
    "$COMPONENT/issues-server.pkg" >/dev/null

sed "s/__VERSION__/$VERSION/" Scripts/pkg/distribution.xml.template > "$BUILD/distribution.xml"

PRODUCT="$BUILD/Issues-$VERSION.pkg"

# Written out twice rather than assembled in an array: macOS ships bash 3.2, where
# expanding an empty array under `set -u` is itself an error.
if [[ -n "${PKG_SIGN_IDENTITY:-}" ]]; then
    productbuild \
        --distribution "$BUILD/distribution.xml" \
        --package-path "$COMPONENT" \
        --resources Scripts/pkg/resources \
        --sign "$PKG_SIGN_IDENTITY" \
        "$PRODUCT" >/dev/null
else
    echo "Note: unsigned. Set PKG_SIGN_IDENTITY to sign for distribution."
    productbuild \
        --distribution "$BUILD/distribution.xml" \
        --package-path "$COMPONENT" \
        --resources Scripts/pkg/resources \
        "$PRODUCT" >/dev/null
fi

echo "Built $PRODUCT"
