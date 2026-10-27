#!/bin/bash
# Télécharge VLCKit (Mac) et MobileVLCKit (iPhone) depuis VideoLAN, vérifie leur empreinte
# SHA-256 (celle des podspecs officiels) et place les xcframeworks dans Vendor/.
# Trop lourds pour git : à lancer une fois après un clone.
#
# Usage : bash scripts/fetch-vlckit.sh

set -euo pipefail

VERSION="3.7.3"
BASE="https://download.videolan.org/pub/cocoapods/prod"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Vendor"

# nom de l'archive | empreinte | xcframework attendu
PACKAGES="
MobileVLCKit-$VERSION-319ed2c0-79128878.tar.xz|0d04059906962ddc9a7bd1ebaa12e1f9ae85eb2466116a97a2f46886dd27a0a9|MobileVLCKit.xcframework
VLCKit-$VERSION-319ed2c0-79128878.tar.xz|019afdae4e2e2d0f3ac325fac8f7ba0af25dca70b9d157df7d60db88e0be8e5d|VLCKit.xcframework
"

mkdir -p "$VENDOR"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

for entry in $PACKAGES; do
    IFS='|' read -r archive sha framework <<< "$entry"
    if [ -d "$VENDOR/$framework" ] && [ "$(cat "$VENDOR/$framework.version" 2>/dev/null)" = "$VERSION" ]; then
        echo "$framework $VERSION déjà présent"
        continue
    fi

    echo "Téléchargement de $archive…"
    curl -fL --progress-bar -o "$WORK/$archive" "$BASE/$archive"
    echo "$sha  $WORK/$archive" | shasum -a 256 -c - >/dev/null || { echo "Empreinte incorrecte pour $archive"; exit 1; }

    mkdir -p "$WORK/extract-$framework"
    tar -xJf "$WORK/$archive" -C "$WORK/extract-$framework"
    found=$(find "$WORK/extract-$framework" -maxdepth 4 -type d -name "$framework" | head -1)
    [ -n "$found" ] || { echo "$framework introuvable dans l'archive"; exit 1; }

    # L'app vise iOS 17 : les tranches 32 bits (armv7, i386) ne servent qu'à alourdir l'iPhone.
    for binary in "$found"/ios-*/*.framework/MobileVLCKit; do
        [ -f "$binary" ] || continue
        for arch in armv7 armv7s i386; do
            if lipo -archs "$binary" | tr ' ' '\n' | grep -qx "$arch"; then
                lipo -remove "$arch" "$binary" -output "$binary"
            fi
        done
    done
    if [ -f "$found/Info.plist" ] && [ "$framework" = "MobileVLCKit.xcframework" ]; then
        python3 -I - "$found/Info.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, "rb") as f:
    info = plistlib.load(f)
for library in info["AvailableLibraries"]:
    library["SupportedArchitectures"] = [a for a in library["SupportedArchitectures"] if a not in ("armv7", "armv7s", "i386")]
with open(path, "wb") as f:
    plistlib.dump(info, f)
PY
    fi

    rm -rf "$VENDOR/$framework"
    mv "$found" "$VENDOR/$framework"
    echo "$VERSION" > "$VENDOR/$framework.version"
    echo "$framework $VERSION installé"
done
