#!/usr/bin/env bash
# Turn the staged OBS install plus the private jellyfin-ffmpeg into a .deb.
source "$(dirname "$0")/common.sh"
resolve_versions

PKG_DIR="$WORK_DIR/pkg"
STAGE="$PKG_DIR/debian/obs-studio"
[[ -x "$STAGE/usr/bin/obs" ]] || die "run build-obs.sh first"

ARCH="$(deb_arch)"
CODENAME="$(codename)"
JF_PLAIN="${JF_VERSION#v}"
# 32.2.2 + v8.1.3-1 on trixie -> 32.2.2+jf8.1.3.1-1~trixie
# ('-' in an OBS pre-release becomes '~' so it sorts before the final release.)
DEB_VERSION="${OBS_VERSION//-/\~}+jf${JF_PLAIN//-/.}-1~${CODENAME}"

group "Bundle jellyfin-ffmpeg runtime"
mkdir -p "$STAGE$FFMPEG_PREFIX"
cp -dR --preserve=mode "$FFMPEG_PREFIX/lib" "$FFMPEG_PREFIX/bin" "$STAGE$FFMPEG_PREFIX/"
# Development files are only needed to build OBS itself.
rm -rf "$STAGE$FFMPEG_PREFIX/lib/pkgconfig" "$STAGE$FFMPEG_PREFIX/lib/cmake"
find "$STAGE$FFMPEG_PREFIX" -name '*.a' -delete
endgroup

group "Debian-style fixups"
# Same clean-ups Debian's obs-studio packaging does in execute_after_dh_auto_install:
# build-only flags in the .pc files break third-party plugin builds (-Werror!).
find "$STAGE" -type f -name '*.pc' -exec \
  sed -e 's| -fPIC | |g' -e 's| -fvisibility=hidden | |g' -e 's/ -Werror\b//' -i {} +
find "$STAGE" -type f -name '*.pem' -exec chmod a-x {} +

DOC="$STAGE/usr/share/doc/obs-studio"
mkdir -p "$DOC/rockchip-mpp"
source_url="${GITHUB_REPOSITORY:+https://github.com/$GITHUB_REPOSITORY}"
: "${source_url:=the obs-jfmpp build repository}"
sed "s|@SOURCE_URL@|$source_url|" "$REPO_ROOT/packaging/copyright" > "$DOC/copyright"
cp "$SRC_DIR"/rkmpp/LICENSES/* "$DOC/rockchip-mpp/"
cef_license="$(ls "$WORK_DIR"/cef/cef_binary_*/LICENSE.txt 2>/dev/null | head -n1)"
[[ -n "$cef_license" ]] && cp "$cef_license" "$DOC/LICENSE.cef"
endgroup

mapfile -t elfs < <(find "$STAGE" -type f -exec file -N {} + | awk -F: '/ELF/ {print $1}')

group "Strip binaries"
# CEF ships libcef.so with full debug info (~2 GB); FFmpeg/MPP/RGA install unstripped.
strip --strip-unneeded "${elfs[@]}"
endgroup

group "Point OBS at the private FFmpeg (RUNPATH)"
# OBS sets an empty INSTALL_RPATH on its targets unless built relocatable, so
# CMAKE_INSTALL_RPATH has no effect; patch the installed binaries instead.
# The FFmpeg libraries were linked with --enable-rpath; MPP/RGA were not.
for f in "${elfs[@]}"; do
  if [[ "$f" == "$STAGE$FFMPEG_PREFIX"/* ]]; then
    [[ -n "$(patchelf --print-rpath "$f")" ]] || patchelf --set-rpath '$ORIGIN' "$f"
    continue
  fi
  if patchelf --print-needed "$f" | grep -qE '^lib(avcodec|avformat|avutil|avfilter|avdevice|swscale|swresample)\.so'; then
    patchelf --add-rpath "$FFMPEG_PREFIX/lib" "$f"
    echo "${f#"$STAGE"}"
  fi
done
endgroup

group "Compute dependencies"
mkdir -p "$PKG_DIR/debian"
cat > "$PKG_DIR/debian/control" <<CTRL
Source: obs-studio

Package: obs-studio
Architecture: $ARCH
CTRL
(
  cd "$PKG_DIR"
  # Libraries shipped inside this package (libobs, ffmpeg, mpp, rga) have no
  # shlibs info; --ignore-missing-info lets dpkg-shlibdeps skip them.
  dpkg-shlibdeps -O --ignore-missing-info \
    -l"$STAGE/usr/lib/$(multiarch)" -l"$STAGE$FFMPEG_PREFIX/lib" \
    "${elfs[@]/#/-e}" 2>dpkg-shlibdeps.log
) > "$PKG_DIR/substvars" || { cat "$PKG_DIR/dpkg-shlibdeps.log"; exit 1; }
shlibs="$(sed -n 's/^shlibs:Depends=//p' "$PKG_DIR/substvars")"
[[ -n "$shlibs" ]] || die "dpkg-shlibdeps produced no dependencies"
endgroup

group "Build obs-studio $DEB_VERSION"
installed_size="$(du -sk --exclude=DEBIAN "$STAGE" | cut -f1)"
mkdir -p "$STAGE/DEBIAN"
cat > "$STAGE/DEBIAN/control" <<CTRL
Package: obs-studio
Version: $DEB_VERSION
Architecture: $ARCH
Maintainer: obs-jfmpp <noreply@github.com>
Installed-Size: $installed_size
Depends: $shlibs, qt6-qpa-plugins, qt6-svg-plugins, qt6-wayland, qt6-image-formats-plugins
Recommends: vlc-plugin-base
Suggests: pkexec | polkitd, v4l2loopback-dkms
Conflicts: libobs0, libobs0t64, libobs-dev, obs-plugins, obs-studio-common
Replaces: libobs0, libobs0t64, libobs-dev, obs-plugins, obs-studio-common
Section: video
Priority: optional
Homepage: https://obsproject.com/
Description: OBS Studio built against jellyfin-ffmpeg with Rockchip MPP
 OBS Studio $OBS_VERSION linked against a private copy of jellyfin-ffmpeg
 $JF_VERSION (installed in $FFMPEG_PREFIX) built with --enable-rkmpp and
 --enable-rkrga. Adds native "Rockchip MPP H.264/HEVC" encoders to OBS's
 Simple and Advanced output modes, and includes the browser source (CEF).
 .
 NVENC, QSV, AJA and WebRTC output are not included.
CTRL

mkdir -p "$OUT_DIR"
DEB="$OUT_DIR/obs-studio_${OBS_VERSION}-jf${JF_PLAIN}_${CODENAME}_${ARCH}.deb"
dpkg-deb --root-owner-group -Zxz --build "$STAGE" "$DEB"
dpkg-deb --info "$DEB"
endgroup

log "Built $DEB"
