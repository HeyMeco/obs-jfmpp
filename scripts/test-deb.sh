#!/usr/bin/env bash
# Install the built .deb and check it is wired to jellyfin-ffmpeg.
# Meant for a fresh, throwaway container (run as root).
source "$(dirname "$0")/common.sh"

deb="${1:-$(ls "$OUT_DIR"/obs-studio_*.deb | head -n1)}"
[[ -f "$deb" ]] || die "no .deb found"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends "$(realpath "$deb")"

ffmpeg="$FFMPEG_PREFIX/bin/ffmpeg"
"$ffmpeg" -hide_banner -version | head -n1
encoders="$("$ffmpeg" -hide_banner -encoders)"
decoders="$("$ffmpeg" -hide_banner -decoders)"
for codec in h264_rkmpp hevc_rkmpp; do
  grep -q " $codec " <<<"$encoders" || die "encoder $codec missing"
  grep -q " $codec " <<<"$decoders" || die "decoder $codec missing"
done

FFLIBS='lib(avcodec|avformat|avutil|avfilter|avdevice|swscale|swresample|postproc)\.so'

# Every OBS binary that links FFmpeg must resolve it to the private copy.
bad=0
while read -r f; do
  deps="$(ldd "$f")"
  if grep -E "$FFLIBS" <<<"$deps" | grep -qv "$FFMPEG_PREFIX"; then
    echo "$f resolves FFmpeg outside $FFMPEG_PREFIX:"; ldd "$f" | grep -E "$FFLIBS"
    bad=1
  fi
  if grep -q 'not found' <<<"$deps"; then
    echo "$f has unresolved libraries:"; ldd "$f" | grep 'not found'
    bad=1
  fi
done < <(find /usr/bin/obs /usr/lib/*/libobs*.so* /usr/lib/*/obs-plugins "$FFMPEG_PREFIX" -type f -name '*.so*' -o -type f -perm -u+x)
[[ $bad -eq 0 ]] || die "library resolution check failed"

plugins="$(echo /usr/lib/*/obs-plugins)"
[[ -f "$plugins/obs-browser.so" && -f "$plugins/libcef.so" ]] || die "browser source (CEF) missing"
grep -q ffmpeg_rkmpp_h264 "$plugins/obs-ffmpeg.so" || die "obs-ffmpeg lacks the rkmpp encoders"
grep -q 'Hardware.RKMPP.H264' /usr/share/obs/obs-studio/locale/en-US.ini || die "Simple mode rkmpp strings missing"

ldd "$plugins/obs-ffmpeg.so" | grep -E 'libavcodec|rockchip_mpp|librga' || true
# Same as Debian's autopkgtest for obs-studio.
QT_QPA_PLATFORM=offscreen obs --version
QT_QPA_PLATFORM=offscreen obs --help >/dev/null
[[ -f /usr/share/doc/obs-studio/copyright ]] || die "copyright file missing"
if grep -q -- '-Werror' /usr/lib/*/pkgconfig/libobs.pc; then die "libobs.pc still has -Werror"; fi
log "Smoke test passed"
