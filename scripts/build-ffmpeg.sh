#!/usr/bin/env bash
# Build Rockchip MPP + RGA and jellyfin-ffmpeg (shared) into $FFMPEG_PREFIX.
source "$(dirname "$0")/common.sh"
resolve_versions

[[ "$(deb_arch)" == arm64 ]] || die "rkmpp is only available on arm64 (got $(deb_arch))"

SUDO=""
[[ $EUID -ne 0 ]] && SUDO="sudo"
$SUDO mkdir -p "$FFMPEG_PREFIX"
$SUDO chown "$(id -u):$(id -g)" "$FFMPEG_PREFIX"

export PKG_CONFIG_PATH="$FFMPEG_PREFIX/lib/pkgconfig"

group "Rockchip MPP ($RKMPP_BRANCH)"
fetch_git rkmpp "$RKMPP_REPO" "$RKMPP_BRANCH"
cmake -S "$SRC_DIR/rkmpp" -B "$WORK_DIR/rkmpp" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$FFMPEG_PREFIX" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DBUILD_SHARED_LIBS=ON \
  -DBUILD_TEST=OFF
cmake --build "$WORK_DIR/rkmpp" -j "$JOBS"
cmake --install "$WORK_DIR/rkmpp"
endgroup

group "Rockchip RGA ($RKRGA_BRANCH)"
fetch_git rkrga "$RKRGA_REPO" "$RKRGA_BRANCH"
[[ -d "$WORK_DIR/rkrga" ]] || meson setup "$WORK_DIR/rkrga" "$SRC_DIR/rkrga" \
  --prefix="$FFMPEG_PREFIX" \
  --libdir=lib \
  --buildtype=release \
  --default-library=shared \
  -Dcpp_args=-fpermissive \
  -Dlibdrm=false \
  -Dlibrga_demo=false
ninja -C "$WORK_DIR/rkrga" -j "$JOBS" install
endgroup

group "jellyfin-ffmpeg $JF_VERSION"
fetch_git jellyfin-ffmpeg https://github.com/jellyfin/jellyfin-ffmpeg.git "$JF_VERSION"
cd "$SRC_DIR/jellyfin-ffmpeg"
# The repo carries upstream FFmpeg plus Jellyfin's changes as a quilt series.
if [[ ! -f .pc/.quilt_series ]]; then
  QUILT_PATCHES=debian/patches quilt --quiltrc /dev/null push -a
fi

# Based on jellyfin-ffmpeg's debian/rules (arm64), restricted to libraries the
# distro ships so the result only depends on stock Debian/Ubuntu packages.
config=(
  --prefix="$FFMPEG_PREFIX"
  --extra-version=jellyfin  # lowercase: OBS's FindFFmpeg version regex rejects capitals
  --enable-rpath
  --target-os=linux
  --arch=arm64
  --disable-doc
  --disable-ffplay
  --disable-static
  --enable-shared
  --enable-gpl
  --enable-version3
  --disable-libxcb
  --disable-xlib
  --disable-sdl2
  --enable-gnutls
  --enable-libdrm
  --enable-vaapi
  --enable-rkmpp
  --enable-rkrga
  --enable-libx264
  --enable-libx265
  --enable-libvpx
  --enable-libsvtav1
  --enable-libdav1d
  --enable-libopus
  --enable-libmp3lame
  --enable-libvorbis
  --enable-libwebp
  --enable-libass
  --enable-libfreetype
  --enable-libfontconfig
  --enable-libfribidi
  --enable-libharfbuzz
  --enable-libzimg
  --enable-libsrt
)
./configure "${config[@]}" || { tail -n 50 ffbuild/config.log; exit 1; }
make -j "$JOBS"
make install
endgroup

encoders="$("$FFMPEG_PREFIX/bin/ffmpeg" -hide_banner -encoders)"
grep -q ' h264_rkmpp ' <<<"$encoders" || die "built ffmpeg has no h264_rkmpp encoder"
log "jellyfin-ffmpeg installed to $FFMPEG_PREFIX"
