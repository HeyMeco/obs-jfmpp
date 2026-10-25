#!/usr/bin/env bash
# Build OBS Studio (with the patches in patches/obs-studio/<version> and the CEF build
# OBS pins for this release) against the jellyfin-ffmpeg in $FFMPEG_PREFIX, and
# install it into the staging root $WORK_DIR/pkg/debian/obs-studio-rockchip.
#
# Env: CEF_VERSION / CEF_REVISION / CEF_SHA256 override the pinned CEF build.
source "$(dirname "$0")/common.sh"
resolve_versions

[[ -f "$FFMPEG_PREFIX/lib/pkgconfig/libavcodec.pc" ]] || die "run build-ffmpeg.sh first"
PATCH_DIR="$(obs_patch_dir "$OBS_VERSION")"

group "Fetch OBS Studio $OBS_VERSION"
fetch_git obs-studio https://github.com/obsproject/obs-studio.git "$OBS_VERSION" \
  --recurse-submodules --shallow-submodules
endgroup

group "Apply patches from patches/obs-studio/$(basename "$PATCH_DIR")"
OBS_SRC="$SRC_DIR/obs-studio"
# Start from a pristine tree so re-runs (and patch updates) apply cleanly.
git -C "$OBS_SRC" reset -q --hard HEAD
git -C "$OBS_SRC" clean -qfd
for patch in "$PATCH_DIR"/*.patch; do
  echo "$(basename "$patch")"
  git -C "$OBS_SRC" apply --whitespace=nowarn "$patch" \
    || die "$(basename "$patch") does not apply to OBS $OBS_VERSION; refresh it"
done
endgroup

group "Chromium Embedded Framework"
# OBS pins the CEF build its obs-browser revision is written against.
cef_target="ubuntu-$(uname -m)"
read -r cef_pin_version cef_base_url cef_pin_hash cef_pin_revision < <(
  jq -r --arg t "$cef_target" '
    .configurePresets[] | select(.name == "dependencies")
    | .vendor["obsproject.com/obs-studio"].dependencies.cef
    | "\(.version) \(.baseUrl) \(.hashes[$t] // "-") \(.revision[$t] // "-")"
  ' "$OBS_SRC/CMakePresets.json"
)
if [[ -n "${CEF_VERSION:-}" ]]; then
  cef_version="$CEF_VERSION"
  cef_revision="${CEF_REVISION:-}"
  cef_hash="${CEF_SHA256:-}"
else
  cef_version="$cef_pin_version"
  cef_revision="${cef_pin_revision#-}"
  cef_hash="${cef_pin_hash#-}"
fi
cef_name="cef_binary_${cef_version}_linux_$(uname -m)${cef_revision:+_v$cef_revision}"
CEF_DIR="$WORK_DIR/cef/$cef_name"
if [[ ! -f "$CEF_DIR/.complete" ]]; then
  mkdir -p "$WORK_DIR/cef"
  curl -fL --retry 3 -o "$WORK_DIR/cef/$cef_name.tar.xz" "$cef_base_url/$cef_name.tar.xz"
  if [[ -n "$cef_hash" ]]; then
    echo "$cef_hash  $WORK_DIR/cef/$cef_name.tar.xz" | sha256sum -c - || die "CEF checksum mismatch"
  else
    log "No checksum known for $cef_name; skipping verification"
  fi
  rm -rf "$CEF_DIR" && mkdir -p "$CEF_DIR"
  XZ_OPT=-T0 tar --no-same-owner -xJf "$WORK_DIR/cef/$cef_name.tar.xz" --strip-components=1 -C "$CEF_DIR"
  rm "$WORK_DIR/cef/$cef_name.tar.xz"
  touch "$CEF_DIR/.complete"
fi
log "Using $cef_name"
endgroup

group "Build OBS Studio $OBS_VERSION"
# CMake caches the paths it found (CEF's library and headers among them), so a build
# directory configured for another OBS release or CEF build has to start over.
build_id="$OBS_VERSION $cef_name"
if [[ -d "$WORK_DIR/obs" && "$(cat "$WORK_DIR/obs/.build-id" 2>/dev/null)" != "$build_id" ]]; then
  log "Starting a clean build directory for $build_id"
  rm -rf "$WORK_DIR/obs"
fi
mkdir -p "$WORK_DIR/obs"
echo "$build_id" > "$WORK_DIR/obs/.build-id"
export PKG_CONFIG_PATH="$FFMPEG_PREFIX/lib/pkgconfig"
# RelWithDebInfo without its -g: the install and the packaging strip the debug info
# anyway, so generating it only slows down compiling and linking.
cmake -S "$SRC_DIR/obs-studio" -B "$WORK_DIR/obs" -G Ninja \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_C_FLAGS_RELWITHDEBINFO="-O2 -DNDEBUG" \
  -DCMAKE_CXX_FLAGS_RELWITHDEBINFO="-O2 -DNDEBUG" \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DCMAKE_INSTALL_LIBDIR="lib/$(multiarch)" \
  -DCMAKE_PREFIX_PATH="$FFMPEG_PREFIX" \
  -DOBS_VERSION_OVERRIDE="$OBS_VERSION" \
  -DENABLE_BROWSER=ON \
  -DCEF_ROOT_DIR="$CEF_DIR" \
  -DENABLE_RKMPP=ON \
  -DENABLE_AJA=OFF \
  -DENABLE_WEBRTC=OFF \
  -DENABLE_NVENC=OFF \
  -DENABLE_LIBFDK=OFF \
  -DENABLE_VLC=ON \
  -DENABLE_WAYLAND=ON \
  -DENABLE_PIPEWIRE=ON \
  -DENABLE_JACK=ON \
  -DENABLE_SNDIO=ON \
  "${CMAKE_CCACHE[@]}"

# Make sure OBS really picked up jellyfin-ffmpeg and not something else.
grep -E '^FFmpeg_avcodec_INCLUDE_DIR' "$WORK_DIR/obs/CMakeCache.txt" | grep -q "$FFMPEG_PREFIX" \
  || die "OBS did not find jellyfin-ffmpeg in $FFMPEG_PREFIX"
grep -E '^CEF_LIBRARY_RELEASE' "$WORK_DIR/obs/CMakeCache.txt" | grep -q "$CEF_DIR/" \
  || die "OBS did not pick up $cef_name"

cmake --build "$WORK_DIR/obs" -j "$JOBS"
endgroup

group "Install OBS Studio into staging root"
STAGE="$WORK_DIR/pkg/debian/obs-studio-rockchip"
rm -rf "$WORK_DIR/pkg"
DESTDIR="$STAGE" cmake --install "$WORK_DIR/obs" --strip
endgroup
