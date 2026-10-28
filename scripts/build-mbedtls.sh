#!/usr/bin/env bash
# Build mbedTLS 3 (static, position-independent) into $FFMPEG_PREFIX when the distro
# only has mbedTLS 2 (Ubuntu Noble): OBS 33's obs-outputs needs 3.x. Linked statically,
# so nothing extra ships in the package. Runs after build-ffmpeg.sh, which empties
# the prefix when it rebuilds.
source "$(dirname "$0")/common.sh"

MBEDTLS_VERSION="${MBEDTLS_VERSION:-3.6.7}"
MBEDTLS_SHA256="${MBEDTLS_SHA256:-a7e8bcbec0e6f761b4af24f25677626b35f762f68eef79c08677a363212d11f6}"

distro="$(dpkg-query -W -f='${Version}' libmbedtls-dev 2>/dev/null || true)"
if [[ -n "$distro" ]] && dpkg --compare-versions "$distro" ge 3; then
  log "Using the distro's mbedTLS $distro"
  exit 0
fi

build_id="mbedtls-$MBEDTLS_VERSION script-$(sha256sum "$0" | cut -c1-16)"
if [[ "$(cat "$FFMPEG_PREFIX/.mbedtls-build-id" 2>/dev/null)" == "$build_id" ]]; then
  log "Reusing mbedTLS in $FFMPEG_PREFIX ($build_id)"
  exit 0
fi

group "mbedTLS $MBEDTLS_VERSION (distro has ${distro:-none})"
name="mbedtls-$MBEDTLS_VERSION"
mkdir -p "$SRC_DIR"
curl -fL --retry 3 -o "$SRC_DIR/$name.tar.bz2" \
  "https://github.com/Mbed-TLS/mbedtls/releases/download/$name/$name.tar.bz2"
echo "$MBEDTLS_SHA256  $SRC_DIR/$name.tar.bz2" | sha256sum -c - || die "mbedTLS checksum mismatch"
rm -rf "$SRC_DIR/$name"
tar -xjf "$SRC_DIR/$name.tar.bz2" -C "$SRC_DIR"
rm "$SRC_DIR/$name.tar.bz2"
rm -rf "$WORK_DIR/mbedtls"
cmake -S "$SRC_DIR/$name" -B "$WORK_DIR/mbedtls" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCMAKE_INSTALL_PREFIX="$FFMPEG_PREFIX" \
  -DUSE_SHARED_MBEDTLS_LIBRARY=OFF \
  -DENABLE_PROGRAMS=OFF \
  -DENABLE_TESTING=OFF \
  "${CMAKE_CCACHE[@]}"
cmake --build "$WORK_DIR/mbedtls" -j "$JOBS"
cmake --install "$WORK_DIR/mbedtls"
endgroup

echo "$build_id" > "$FFMPEG_PREFIX/.mbedtls-build-id"
log "mbedTLS installed to $FFMPEG_PREFIX"
