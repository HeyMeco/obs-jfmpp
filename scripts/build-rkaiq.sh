#!/usr/bin/env bash
# Build Rockchip's camera 3A engine (librkaiq, RK3588 ISP) into $FFMPEG_PREFIX,
# plus the RK3588 sensor tuning files, for the Rockchip Camera source.
# Runs after build-ffmpeg.sh, which empties the prefix when it rebuilds.
source "$(dirname "$0")/common.sh"

[[ "$(deb_arch)" == arm64 ]] || die "rkaiq is only available on arm64 (got $(deb_arch))"

# The SDK mirror carries prebuilt binaries and tuning files for every Rockchip
# ISP (about 1 GB); check out only the library and the RK3588 (ISP3x) tuning.
fetch_git rkaiq "$RKAIQ_REPO" "$RKAIQ_BRANCH" --filter=blob:none --no-checkout
src="$SRC_DIR/rkaiq"
git -C "$src" sparse-checkout set --no-cone /NOTICE '/rkaiq/' '!/rkaiq/iqfiles/' '/rkaiq/iqfiles/isp3x/'
git -C "$src" reset -q --hard

patches=("$REPO_ROOT"/patches/rkaiq/*.patch)
build_id="rkaiq-$(git -C "$src" rev-parse HEAD) script-$(cat "$0" "${patches[@]}" | sha256sum | cut -c1-16)"
if [[ "$(cat "$FFMPEG_PREFIX/.rkaiq-build-id" 2>/dev/null)" == "$build_id" && -f "$FFMPEG_PREFIX/lib/librkaiq.so" ]]; then
  log "Reusing rkaiq in $FFMPEG_PREFIX ($build_id)"
  exit 0
fi

group "Rockchip rkaiq ($RKAIQ_BRANCH)"
git -C "$src" apply "${patches[@]}"
# ISP_HW_V30 is the RK3588 ISP. Autofocus needs a lens driver (VCM), lens
# distortion correction (off in the tuning files) a prebuilt library kept in Git
# LFS, and the binary IQ format an extra conversion step; none is used here. RGA
# would only scale thumbnails. Its build installs host tools into the install
# prefix while building, so that points elsewhere; the library and headers are
# copied below. Vendor code: keep its many warnings out of the log.
cmake -S "$src/rkaiq" -B "$WORK_DIR/rkaiq" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_FLAGS=-w -DCMAKE_CXX_FLAGS=-w \
  -DCMAKE_DISABLE_FIND_PACKAGE_librga=ON \
  -DCMAKE_INSTALL_PREFIX="$WORK_DIR/rkaiq/unused-prefix" \
  -DRKAIQ_TARGET_SOC=rk3588 \
  -DISP_HW_VERSION=-DISP_HW_V30 \
  -DARCH=aarch64 \
  -DRKAIQ_BUILD_BINARY_IQ=OFF \
  -DRKAIQ_ENABLE_AF=OFF \
  -DRKAIQ_GENMESH_ONLINE=OFF \
  -DRKAIQ_J2S4B_DEV=OFF \
  -DCMAKE_SKIP_RPATH=TRUE \
  "${CMAKE_CCACHE[@]}"
cmake --build "$WORK_DIR/rkaiq" -j "$JOBS" --target rkaiq
install -Dm644 -t "$FFMPEG_PREFIX/lib" "$WORK_DIR/rkaiq/all_lib/Release/librkaiq.so"
rm -rf "$FFMPEG_PREFIX/include/rkaiq"
(cd "$src/rkaiq/include" && find . -name '*.h' -exec install -Dm644 {} "$FFMPEG_PREFIX/include/rkaiq/{}" \;)
install -Dm644 "$WORK_DIR/rkaiq/config.h" "$FFMPEG_PREFIX/include/rkaiq/config.h"
endgroup

group "RK3588 camera tuning files"
iq="$FFMPEG_PREFIX/share/rkaiq/iqfiles"
rm -rf "$iq"
install -Dm644 -t "$iq" "$src"/rkaiq/iqfiles/isp3x/*.json
# Radxa ships Rockchip's IMX415 tuning unchanged under its camera module's name.
ln -s imx415_CMK-OT2022-PX1_IR0147-50IRC-8M-F20.json "$iq/imx415_RADXA-CAMERA-4K_DEFAULT.json"
endgroup

echo "$build_id" > "$FFMPEG_PREFIX/.rkaiq-build-id"
log "rkaiq installed to $FFMPEG_PREFIX"
