#!/bin/sh
# Maintainer build only. Students use the resulting AppImage without Docker.
set -eu
[ "$(uname -m)" = x86_64 ] || { echo 'Build on Linux x86-64.' >&2; exit 2; }
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
image=${CPU2026_BUILD_IMAGE:-cpu2026}
output=${CPU2026_DIST_DIR:-"$root/build/appimage"}
mkdir -p "$output"
output=$(CDPATH= cd -- "$output" && pwd)
: "${APPIMAGETOOL:?Set APPIMAGETOOL to the appimagetool executable}"
# Rootless Docker maps container root to the invoking user.
if docker info --format '{{.SecurityOptions}}' | grep -q rootless; then
    container_user=0:0
else
    container_user=$(id -u):$(id -g)
fi
docker run --rm --network none --user "$container_user" \
    -v "$root:/source:ro" -v "$output:/output" "$image" \
    python3 /source/packaging/appimage/bundle.py
sha256sum "$APPIMAGETOOL" > "$output/appimagetool-SHA256SUMS"
ARCH=x86_64 "$APPIMAGETOOL" --appimage-extract-and-run \
    "$output/CPU2026-Tools.AppDir" "$output/cpu2026-tools-x86_64.AppImage"
(cd "$output" && sha256sum cpu2026-tools-x86_64.AppImage > SHA256SUMS)
docker image inspect --format '{{.Id}}' "$image" > "$output/build-image-id.txt"
