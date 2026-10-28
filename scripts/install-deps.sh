#!/usr/bin/env bash
# Install build dependencies on Debian Trixie / Ubuntu Noble / Ubuntu Resolute (arm64).
# Deliberately does NOT install the distro libav*-dev packages: OBS must only
# ever see jellyfin-ffmpeg's headers and pkg-config files.
source "$(dirname "$0")/common.sh"

export DEBIAN_FRONTEND=noninteractive
SUDO=""
[[ $EUID -ne 0 ]] && SUDO="sudo"

# The builder image of docker-build.sh already ran this exact script.
STAMP=/var/lib/obs-jfmpp-deps
stamp="$(sha256sum "$0" | cut -d' ' -f1)"
if [[ "$(cat "$STAMP" 2>/dev/null)" == "$stamp" ]]; then
  log "Build dependencies already installed"
  exit 0
fi

# Ubuntu keeps some of these in universe; make sure it is enabled.
if grep -qi ubuntu /etc/os-release; then
  $SUDO sed -i 's/^Components: main.*$/Components: main restricted universe multiverse/' \
    /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null || true
fi

$SUDO apt-get update

# First package of each "a|b" group that exists in this release.
pick() {
  local alt
  for alt in ${1//|/ }; do
    if apt-cache show "$alt" >/dev/null 2>&1; then
      echo "$alt"
      return
    fi
  done
  die "none of '$1' is available"
}

tools=(
  build-essential cmake ninja-build meson pkgconf git ca-certificates curl jq xz-utils
  quilt nasm patchelf dpkg-dev file python3 ccache
  m4 xxd  # rkaiq generates its IQ parser with them
)

ffmpeg_deps=(
  libdrm-dev libva-dev libgnutls28-dev
  libx264-dev libx265-dev libvpx-dev libsvtav1enc-dev libdav1d-dev
  libopus-dev libmp3lame-dev libvorbis-dev libwebp-dev
  libass-dev libfreetype-dev libfontconfig-dev libfribidi-dev libharfbuzz-dev
  libzimg-dev libsrt-openssl-dev
  libssl-dev  # srt.pc requires openssl, and Noble's libsrt-openssl-dev doesn't depend on it
)

# Mirrors obs-studio's .github/scripts/utils.zsh/setup_ubuntu, minus FFmpeg,
# NVENC, QSV (x86 only) and non-free fdk-aac. CEF is downloaded by build-obs.sh.
obs_deps=(
  libglib2.0-dev extra-cmake-modules libcurl4-openssl-dev libjansson-dev
  libgl-dev libegl-dev libgles-dev libglvnd-dev libwayland-dev libxkbcommon-dev
  libx11-dev libx11-xcb-dev libxcb1-dev libxcb-randr0-dev libxcb-shm0-dev
  libxcb-xinerama0-dev libxcb-composite0-dev libxcb-xfixes0-dev libxinerama-dev
  libxcomposite-dev libxdamage-dev libxss-dev libxrandr-dev
  libatk1.0-dev libatk-bridge2.0-dev libnss3-dev libgbm-dev libcups2-dev
  libpipewire-0.3-dev libpulse-dev libasound2-dev libjack-jackd2-dev libsndio-dev
  libspeexdsp-dev libudev-dev libv4l-dev libvlc-dev libpci-dev
  libmbedtls-dev uthash-dev libsimde-dev libluajit-5.1-dev python3-dev swig
  nlohmann-json3-dev libwebsocketpp-dev libasio-dev libqrcodegencpp-dev librist-dev
  qt6-base-dev qt6-base-private-dev "$(pick 'qt6-svg-dev|libqt6svg6-dev')"
)

$SUDO apt-get install -y --no-install-recommends "${tools[@]}" "${ffmpeg_deps[@]}" "${obs_deps[@]}"

if dpkg-query -W -f='${Status}\n' libavcodec-dev 2>/dev/null | grep -q 'ok installed'; then
  die "libavcodec-dev got pulled in; OBS could pick up the distro FFmpeg headers"
fi

echo "$stamp" | $SUDO tee "$STAMP" >/dev/null
