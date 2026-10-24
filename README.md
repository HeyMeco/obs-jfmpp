<img src="assets/icon.svg" width="64" height="64" alt="OBS Studio logo">

# obs-jfmpp

OBS Studio `.deb` packages for **arm64 Rockchip boards** (RK3588, RK3568, RK3566, …),
built against [jellyfin-ffmpeg](https://github.com/jellyfin/jellyfin-ffmpeg) with
Rockchip MPP/RGA hardware encoding and decoding enabled.

| Target | Container image |
|--------|-----------------|
| Debian 13 Trixie | `debian:trixie` |
| Ubuntu 26.04 Resolute Raccoon | `ubuntu:resolute` |

Prebuilt packages are on the [Releases](../../releases) page.

## Install

```sh
sudo apt install ./obs-studio_<obs>-jf<jellyfin-ffmpeg>_<trixie|resolute>_arm64.deb
```

The package is named `obs-studio` and replaces the distro's `obs-studio`, `obs-studio-common`,
`libobs0t64`, `obs-plugins` and `libobs-dev`. apt removes those automatically. This was tested
over Trixie's OBS 30.2.3 and Resolute's OBS 32.1.0.

### Packaging

The packaging follows Debian's [obs-studio packaging](https://salsa.debian.org/multimedia-team/obs-studio)
where it matters at runtime. That means the same runtime `Depends` (`qt6-svg-plugins`,
`qt6-wayland`, `qt6-image-formats-plugins`), `Suggests: pkexec | polkitd, v4l2loopback-dkms`,
and its install-time clean-ups: build-only flags such as `-Werror` are stripped from the `.pc`
files, and `.pem` files lose the executable bit. It also ships a DEP-5
`/usr/share/doc/obs-studio/copyright` covering OBS, jellyfin-ffmpeg, Rockchip MPP/RGA and CEF.

It deliberately stays a single package, unlike Debian's five-way split. It also skips
Debian-policy-only patches (soname 0, hidden symbols, `obs-ffmpeg-mux` under `/usr/lib`).
Upstream already installs `libobs.so.0` / `libobs-frontend-api.so.0` compatibility links.

## What's in the package

- OBS Studio installed to `/usr` as usual, with:
  - native **Rockchip MPP H.264 / HEVC** encoders, selectable in both Simple and Advanced
    output mode (see [`patches/obs-studio`](patches/obs-studio));
  - the **browser source**, using the CEF build OBS pins for that release, downloaded from
    `cdn-fastly.obsproject.com` and checked against OBS's SHA-256.
- A private copy of jellyfin-ffmpeg (shared libraries plus `ffmpeg`/`ffprobe`),
  Rockchip MPP (`librockchip_mpp`) and RGA (`librga`) in `/usr/lib/obs-jellyfin-ffmpeg`.
  OBS finds it through `RUNPATH`; the system FFmpeg is left untouched and nothing
  else on the system uses this copy.

FFmpeg is built with `--enable-rkmpp --enable-rkrga` plus x264, x265, libvpx, SVT-AV1,
dav1d, Opus, LAME, Vorbis, libass, VA-API, etc. Check it with:

```sh
/usr/lib/obs-jellyfin-ffmpeg/bin/ffmpeg -hide_banner -encoders | grep rkmpp
```

Not included: NVENC, QSV, AJA, WebRTC output, fdk-aac.

### Using the Rockchip encoders in OBS

- **Simple mode:** Settings → Output → Video Encoder → *Hardware (Rockchip MPP, H.264)* or
  *Hardware (Rockchip MPP, HEVC)*, for streaming and for recording. Recording quality presets
  map to constant-QP encoding.
- **Advanced mode:** pick *Rockchip MPP H.264* / *Rockchip MPP HEVC* as the video encoder.
  Settings: rate control (CBR, VBR, CQP), bitrate, max bitrate, QP, keyframe interval
  (0 = 2 s), profile, plus free-form FFmpeg options passed to `h264_rkmpp`/`hevc_rkmpp`
  (e.g. `qp_min=20 qp_max=40`).

OBS feeds the encoder 8-bit NV12/I420 frames; HDR (Rec. 2100) output isn't supported. The
encoders only show up when an MPP device node (`/dev/mpp_service`, `/dev/vpu_service`,
`/dev/rkvenc` or `/dev/vepu`) exists. A profile set to an rkmpp encoder falls back to x264 on
machines without one.

The board needs the Rockchip kernel drivers (`/dev/mpp_service`, `/dev/rga`, `/dev/dma_heap`),
as shipped by vendor/BSP kernels such as Armbian's `vendor` branch or
[ubuntu-rockchip](https://github.com/Joshua-Riek/ubuntu-rockchip).

MPP opens `/dev/mpp_service` read-write and allocates frames from `/dev/dma_heap/*`. Vendor
kernels often restrict both to `root`. The package therefore installs
`/usr/lib/udev/rules.d/70-obs-jfmpp-rockchip.rules`, which gives these nodes and `/dev/rga`
to the `video` group and, through `uaccess`, to the user logged in at the desktop. The rule
is applied on install.

#### Troubleshooting "Failed to init MPP context: -1"

That error means MPP couldn't open a device. Check:

```sh
ls -l /dev/mpp_service /dev/rga /dev/dma_heap/
getfacl /dev/mpp_service          # your user should be listed (uaccess)
journalctl -b -t mpp | tail       # MPP's own reason; OBS also prints it to the terminal
# Test the encoder outside OBS:
/usr/lib/obs-jellyfin-ffmpeg/bin/ffmpeg -f lavfi -i testsrc2=size=1920x1080:rate=30 \
  -t 5 -c:v h264_rkmpp /tmp/rkmpp-test.mp4
```

If the test works with `sudo` but not as your user, it's a permissions problem. Log out and
back in after installing, or add yourself to the `video` group (`sudo usermod -aG video $USER`).

## Automation

[`.github/workflows/build.yml`](.github/workflows/build.yml) runs only on a schedule and on
manual triggers:

- **Schedule (every 6 hours):** checks the latest OBS Studio release. If there's no release
  for it here yet (tag `obs-<version>`, e.g. `obs-32.2.2`), it builds both targets on GitHub's
  arm64 runners using the jellyfin-ffmpeg release current at that moment. It then installs
  each package in a clean container as a smoke test and publishes a GitHub release. A new
  jellyfin-ffmpeg release alone does not trigger a build.
- **Manual (Actions tab → Run workflow):** always builds and tests. Optional inputs:
  `obs_version` and `jf_version` (both default to the latest release). It publishes when the
  OBS release doesn't exist here yet. With `force`, it replaces the packages of an existing
  release, for example to pick up a newer jellyfin-ffmpeg or a packaging fix.

Notes:

- `ubuntu-24.04-arm` runners are free for public repositories.
- GitHub disables scheduled workflows after 60 days without repository activity; re-enable
  it from the Actions tab if that happens.

## Patches and CEF

`patches/obs-studio/*.patch` are applied with `git apply` on top of the OBS release tag. If a
new OBS release changes the code they touch, the build fails at "Apply patches" and the
patches need refreshing against the new tag.

CEF follows the OBS release: the build reads the CEF version, revision and SHA-256 for
`ubuntu-aarch64` from that release's `CMakePresets.json`, so obs-browser and CEF always match.
OBS 32.2.x pins CEF 6533 (Chromium 127). OBS 33 moves to 7871 (Chromium 150), which the build
picks up automatically once 33 is released. To force a different build, set `CEF_VERSION`,
`CEF_REVISION` and optionally `CEF_SHA256`. A CEF that doesn't match the OBS release's
obs-browser may not compile.

## Building locally

Needs Docker on an arm64 host (or with arm64 emulation, which is much slower):

```sh
./scripts/docker-build.sh trixie     # or: resolute
OBS_VERSION=32.2.2 JF_VERSION=v8.1.3-1 ./scripts/docker-build.sh trixie
```

The `.deb` lands in `out/`. Inside a Trixie/Resolute arm64 system or container you can run
`./scripts/build.sh` directly (uses `sudo` for apt and for creating
`/usr/lib/obs-jellyfin-ffmpeg`).

| Script | Does |
|--------|------|
| `scripts/install-deps.sh` | apt build dependencies (no distro `libav*-dev`) |
| `scripts/build-ffmpeg.sh` | Rockchip MPP + RGA, then jellyfin-ffmpeg with its patch series applied |
| `scripts/build-obs.sh` | applies `patches/obs-studio`, fetches and verifies CEF, builds OBS Studio against that FFmpeg, staged install |
| `scripts/package-deb.sh` | bundles FFmpeg, computes `Depends` with `dpkg-shlibdeps`, builds the `.deb` |
| `scripts/test-deb.sh` | installs the `.deb` and checks the rkmpp codecs and library resolution |
