<img src="assets/icon.svg" width="64" height="64" alt="OBS Studio logo">

# obs-jfmpp

OBS Studio `.deb` packages for **arm64 Rockchip boards** (RK3588, RK3568, RK3566, …),
built against [jellyfin-ffmpeg](https://github.com/jellyfin/jellyfin-ffmpeg) with
Rockchip MPP hardware encoding and decoding and RGA 2D acceleration enabled.

| Target | Container image |
|--------|-----------------|
| Debian 13 Trixie | `debian:trixie` |
| Ubuntu 26.04 Resolute Raccoon | `ubuntu:resolute` |

Prebuilt packages are on the [Releases](../../releases) page.

## Install

```sh
sudo apt install ./obs-studio-rockchip_<obs>-jf<jellyfin-ffmpeg>_<trixie|resolute>_arm64.deb
```

The package is named `obs-studio-rockchip`. It provides `obs-studio` and replaces the distro's
`obs-studio`, `obs-studio-common`, `libobs0t64`, `obs-plugins` and `libobs-dev`. apt removes those
automatically. This was tested over Trixie's OBS 30.2.3 and Resolute's OBS 32.1.0. Because the name
differs, `apt upgrade` never swaps it for the distro's OBS or the other way round. Older obs-jfmpp
releases named the package `obs-studio`; installing `obs-studio-rockchip` replaces it the same way.

### Packaging

The packaging follows Debian's [obs-studio packaging](https://salsa.debian.org/multimedia-team/obs-studio)
where it matters at runtime. That means the same runtime `Depends` (`qt6-svg-plugins`,
`qt6-wayland`, `qt6-image-formats-plugins`), `Suggests: pkexec | polkitd, v4l2loopback-dkms`,
and its install-time clean-ups: build-only flags such as `-Werror` are stripped from the `.pc`
files, and `.pem` files lose the executable bit. It also ships a DEP-5
`/usr/share/doc/obs-studio-rockchip/copyright` covering OBS, jellyfin-ffmpeg, Rockchip MPP/RGA and CEF.

It deliberately stays a single package, unlike Debian's five-way split. It also skips
Debian-policy-only patches (soname 0, hidden symbols, `obs-ffmpeg-mux` under `/usr/lib`).
Upstream already installs `libobs.so.0` / `libobs-frontend-api.so.0` compatibility links.

## What's in the package

- OBS Studio installed to `/usr` as usual, with:
  - native **Rockchip MPP H.264 / HEVC** encoders, selectable in both Simple and Advanced
    output mode (see [`patches/obs-studio`](patches/obs-studio));
  - the **browser source**, using the CEF build OBS pins for that release, downloaded from
    `cdn-fastly.obsproject.com` and checked against OBS's SHA-256.
  - automatic **OpenGL 3.3 on Mali GPUs**: Mesa's Panthor/Panfrost drivers (RK3588 and other
    Arm Mali GPUs) don't advertise the GL 3.3 core profile OBS needs. When OBS finds one of
    these drivers at startup, it sets `MESA_GL_VERSION_OVERRIDE=3.3` and
    `MESA_GLSL_VERSION_OVERRIDE=330` itself, so you don't need to export them. Values you set
    yourself take precedence. The OBS log records when this happens.
  - a **Rockchip HDMI Input** source for the RK3588 HDMI receiver (`rk_hdmirx`), see
    [below](#capturing-the-rk3588-hdmi-input).
  - a **Rockchip Camera** source for MIPI CSI camera modules on the RK3588 ISP (e.g. the
    Radxa Camera 4K), see [below](#capturing-an-rk3588-mipi-camera).
- A private copy of jellyfin-ffmpeg (shared libraries plus `ffmpeg`/`ffprobe`),
  Rockchip MPP (`librockchip_mpp`), RGA (`librga`) and the camera 3A engine (`librkaiq`,
  with the RK3588 sensor tuning files) in `/usr/lib/obs-jellyfin-ffmpeg`.
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

The encoders take OBS's frames straight from the GPU: OBS renders NV12, which is drawn into
MPP's own frame buffers and encoded from there, so no frame is read back to the CPU. Reading
frames back is slow on the Mali GPU (4K60 recordings dropped more than half their frames to
rendering lag that way). With an I420 color format OBS hands over system memory frames
instead. Input is 8-bit only; HDR (Rec. 2100) output isn't supported. The
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

### Capturing the RK3588 HDMI input

Add **Sources → Rockchip HDMI Input**. Don't use *Video Capture Device (V4L2)* for this
port.

The HDMI receiver only delivers the pixel format the connected device sends, and can't
convert it. Macs and many PCs send YCbCr 4:4:4 (`NV24`), which the V4L2 source can't use:
it fails with `Unable to set format` and stays black. Even with a format it accepts, the V4L2
source copies every frame on the CPU, which is very slow on this receiver.

The Rockchip HDMI Input source never touches the pixels on the CPU. It exports the capture
buffers as dma-bufs, imports them into the Mali GPU as textures, and converts them to RGB in
a shader. It accepts every format the receiver delivers, so the device's colour settings don't
matter:

| Signal | Receiver format | Path to the GPU |
|--------|-----------------|-----------------|
| RGB, 8-bit | `BGR3` | GPU directly |
| YCbCr 4:4:4, 8-bit | `NV24` | GPU directly |
| YCbCr 4:2:2, 8-bit | `NV16` | GPU directly |
| YCbCr 4:2:0, 8-bit | `NV12` | GPU directly |
| YCbCr 4:2:2, 10-bit | `NV20` | RGA3 → `NV16` → GPU |
| YCbCr 4:2:0, 10-bit | `NV15` | RGA3 → `NV12` → GPU |

The GPU can't sample the receiver's packed 10-bit layout (four samples in five bytes), so the
RK3588's RGA3 unpacks those frames to 8-bit, from each capture buffer into a dma-buf of its
own; the GPU then reads that buffer like an 8-bit capture. RGA isn't used for 8-bit signals:
the GPU reads those capture buffers directly, and an RGA pass would only add a copy. Neither
RGA on the RK3588 can read YCbCr 4:4:4 (`NV24`) anyway; that needs the RGA2-Pro of newer
chips. RGA2 can't read packed 10-bit and only addresses the first 4 GB of RAM, so the source
always uses the two RGA3 cores.

- The resolution and frame rate follow the HDMI signal. When the device changes mode or is
  reconnected, the source restarts by itself; while there is no signal it is empty.
- The source's Properties window shows the signal: resolution, frame rate, pixel clock,
  pixel format, colorimetry and range, whether it is HDR, the receiver's EDID, the conversion path (including the RGA3 time per frame
  for 10-bit signals), the GPU textures, how long it has been capturing, and the dropped
  frames in the last minute and in total (with the share of all frames). *Dropped* counts
  frames lost although OBS could have shown them; frames left out because the signal runs
  faster than the OBS frame rate (e.g. 120 Hz into a 60 FPS canvas) are listed separately as
  *skipped*. Frames OBS itself misses to rendering lag show up in OBS's stats, not here. Without a
  signal it shows why, e.g. *No HDMI signal*. It updates by itself when the signal changes;
  **Refresh** updates the capture time, frame counts and timings. **Disconnect** stops capturing and
  closes the receiver's video and audio devices so other programs can use them, until
  **Connect** (or restarting OBS).
- The OBS log shows the detected signal, e.g. `Capturing 1920x1080p @ 60.00 Hz, NV24, 8
  buffers`, a line every 10 s while frames are being dropped (e.g. `3 frames dropped in the
  last 10 s (5 in total)`), so drops can be matched to a point in a recording, and the
  capture time and frame counts when capture stops.
- Up to 3840x2160p60. Sources usually send 4K60 as YCbCr 4:2:0 (`NV12`).
- The vendor driver only reprograms its DMA for a new pixel encoding on hotplug. When a
  source switches encoding without replugging (macOS going from 1080p 4:4:4 to 4K 4:2:0,
  for example), the receiver stops delivering frames. The source then resets the receiver
  (at most every 30 s), which takes a few seconds; the log shows *Resetting the HDMI
  receiver*.
- 10-bit signals are converted to 8-bit. HDR10 (PQ) signals are decoded to linear Rec. 709 in
  the shader, and the source reports itself to OBS as HDR: on an SDR canvas OBS tone-maps it,
  the *HDR Tone Mapping* filter works on it, and HDR canvases get it unchanged. The V4L2 format
  never reports a transfer function, so the source reads PQ from the HDR infoframe through the
  driver's private ioctl, and follows HDR being switched on and off. HLG is shown as SDR.
  With **Decode HDR** off, the PQ-encoded Rec. 2020 values pass through untouched as an SDR
  source (washed out), e.g. to tone-map them with a LUT.
- Sources only send 10-bit and HDR when the receiver's EDID advertises them, and the vendor
  driver's default EDID doesn't. Pick one in the source's **EDID** property:
  - *Leave unchanged* (default) keeps whatever the receiver presents.
  - *SDR, up to 4K60 4:2:0 (340 MHz)* is the driver's default.
  - *SDR, up to 4K60 4:4:4 (600 MHz)*.
  - *HDR10 and 10-bit, up to 4K60 (600 MHz)*.
  - *SDR, up to 1440p120, 1080p120 and 4K60 (600 MHz)*.
  - *HDR10 and 10-bit, up to 1440p120, 1080p120 and 4K60 (600 MHz)*.

  The first three are the driver's own EDIDs. The two high refresh rate ones are the
  600 MHz and HDR EDIDs plus 2560x1440 at 120 Hz (preferred) and 60 Hz, 1920x1080 at
  120 and 100 Hz, and monitor ranges up to 120 Hz and 190 kHz, which the driver's EDIDs
  cap at 70 Hz and 140 kHz. 1440p120 HDR arrives as 4:2:2: 10-bit 4:4:4 would need
  622 MHz. All are written through V4L2, so no root access is needed. The
  HDMI source re-detects the receiver as if it was replugged. The choice is re-applied
  whenever capture starts (the driver puts its own EDID back after a system resume), and
  Properties show the EDID the receiver presents. None of the EDIDs offers 10-bit 4:2:0, so
  10-bit 2160p60 arrives as 4:2:2 (`NV20`). For 120 fps recordings, set OBS's frame rate
  (Settings → Video) to 120 as well. The driver's root-only sysfs switch
  (`/sys/devices/platform/fdee0000.hdmirx-controller/hdmirx/hdmirx/edid`) keeps presenting the
  HDR EDID after it was set to `5` once, whatever is written later.
- The receiver has no 10-bit store for 4:4:4 and RGB: when a source sends HDR that way (macOS
  can), it is kept at 8 bits, which may band in gradients. Properties flag this.
- For 10-bit 2160p60 4:2:2 the receiver reports a quarter of the real pixel clock and frame
  rate. The source measures the frame rate from the buffer timestamps, and Properties show
  the measured values next to the reported ones.
- The source also records the HDMI audio (**Capture HDMI audio**, on by default), so it
  shows up in the audio mixer like any other source with audio. The audio comes from the
  receiver's separate ALSA card (`rockchip,hdmiin`), at the sample rate the HDMI source sends,
  in stereo. Properties show whether audio is being recorded or why not, e.g. *the HDMI
  signal carries no audio*.
- Whenever the HDMI source re-detects the receiver (replug, EDID switch, receiver reset), the
  vendor kernel marks an open HDMI-in audio stream as disconnected, and it only works again
  after it was closed and reopened. The source does that by itself. PipeWire doesn't: it
  retries forever and floods the log with `snd_pcm_status error: File descriptor in bad
  state` (tens of thousands of lines a minute, enough to fill Armbian's `/var/log`). So the
  package installs a WirePlumber rule
  (`/usr/share/wireplumber/wireplumber.conf.d/50-obs-jfmpp-hdmiin.conf`) that keeps PipeWire
  away from that card. It applies after logging in again or `systemctl --user restart
  wireplumber`. Don't add the HDMI-in device as *Audio Input Capture*; with the rule in place
  it isn't offered anymore. While PipeWire still holds the card, Properties say so.

### Capturing an RK3588 MIPI camera

Add **Sources → Rockchip Camera** for a camera module on one of the board's MIPI CSI ports,
such as the Radxa Camera 4K (Sony IMX415). The camera's device tree overlay has to be
enabled, e.g. with `armbian-config` or in `/boot/armbianEnv.txt`; the sensor then shows up in
`dmesg` (`imx415 ...: Detected imx415`).

These modules send raw sensor data, which the RK3588's ISP turns into a picture. The ISP
needs Rockchip's 3A engine (rkaiq) to do that well: it reads the ISP's statistics every frame
and sets the exposure, white balance, colour correction, lens shading, noise reduction and
sharpening from a tuning file made for the sensor and lens. Without it the ISP's output is
dark and green, which is what *Video Capture Device (V4L2)* shows for these cameras. The
source runs rkaiq itself while it captures, so no extra service is needed. The package
bundles rkaiq (AIQ v6.0x32, which matches the ISP driver of the vendor 6.1 and 6.12 kernels)
and Rockchip's RK3588 tuning files.

Like the HDMI input, the source never touches the pixels on the CPU: the ISP scales the
picture to the chosen resolution and writes NV12, which the GPU imports from dma-bufs and
converts to RGB in a shader.

- **Camera** lists the sensors found behind the ISP, with their module name (e.g.
  *imx415 (RADXA-CAMERA-4K), /dev/video11*).
- **Resolution**: the full resolution (3840x2160 for the IMX415), or 2560x1440,
  1920x1080 or 1280x720 scaled down by the ISP.
- **Frame rate**: the sensor's rate (30 fps for the IMX415) by default, fixed so OBS gets a
  steady stream. The sensor driver's mode sets the highest rate: the stock IMX415 driver has
  no mode faster than 30 fps on the 4-lane connection, and rkaiq can only slow a mode down.
  Lower fixed rates are available, and *Variable* lets the camera lengthen the
  exposure in low light at the cost of a lower, changing frame rate.
- **Anti-flicker** (50 Hz by default, as in Rockchip's tuning; 60 Hz in the Americas) keeps
  mains-powered lights from causing rolling bands.
- Automatic or manual **exposure** (shutter speed from 1/30 to 1/8000 s, and gain) and
  **white balance** (colour temperature),
  **brightness**, **contrast**, **saturation**, **hue**, **sharpness**, **mirror** and **flip**.
  These apply immediately.
- Properties show the camera module, the tuning file in use, the capture and sensor
  resolution, the measured frame rate, the current exposure (e.g. *1/60 s, gain 2.40x*) and
  white balance, how long the camera has been capturing and the dropped frames, as for the HDMI
  input. **Disconnect** stops the camera until **Connect**.
- The tuning file is picked by sensor, module and lens name from the device tree, as Rockchip's
  own tools do: `<sensor>_<module>_<lens>.json` in `/usr/lib/obs-jellyfin-ffmpeg/share/rkaiq/iqfiles`.
  The Radxa Camera 4K's file is Rockchip's IMX415 tuning (Radxa ships the same file under its
  own name). For a module without its own file, the source uses another one for the same sensor
  and says so in Properties; colours may be off, since lenses and IR filters differ.
- When `rkaiq_3A_server` (from Rockchip's or Radxa's camera packages) is running, it already
  runs the 3A engine for every ISP stream. The source then leaves it to the server and only
  captures; the image settings don't apply then. Stop the server to use them.
- rkaiq asks for realtime scheduling for its threads, which desktop sessions don't get on the
  vendor 6.12 kernel (RT group scheduling); the bundled build falls back to normal scheduling
  instead of running without exposure and white balance control.
- Supported on the RK3588 (ISP 3.0). Only one source can use a camera at a time.

## Automation

[`.github/workflows/build.yml`](.github/workflows/build.yml) runs only on a schedule and on
manual triggers:

- **Schedule (weekly, Mondays 03:23 UTC):** checks the latest OBS Studio release. If there's no release
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

`patches/obs-studio/<version>/*.patch` are applied with `git apply` on top of the OBS release
tag. Each folder holds the patch series refreshed against that OBS release, and the build uses
the folder with the highest version that is not newer than the OBS being built: 33.0.1 uses
`33.0.0/`, 32.2.3 uses `32.2.2/`. If a new OBS release changes the code the patches touch, the
build fails at "Apply patches"; refresh the series against the new tag into a new folder named
after it, and keep the old folder so older releases still build.

CEF follows the OBS release: the build reads the CEF version, revision and SHA-256 for
`ubuntu-aarch64` from that release's `CMakePresets.json`, so obs-browser and CEF always match.
OBS 32.2.x pins CEF 6533 (Chromium 127) and OBS 33 pins 7871 (Chromium 150). To force a different build, set `CEF_VERSION`,
`CEF_REVISION` and optionally `CEF_SHA256`. A CEF that doesn't match the OBS release's
obs-browser may not compile.

## Building locally

Needs Docker on an arm64 host (or with arm64 emulation, which is much slower):

```sh
./scripts/docker-build.sh trixie     # or: resolute
OBS_VERSION=32.2.2 JF_VERSION=v8.1.3-1 ./scripts/docker-build.sh trixie
```

The `.deb` lands in `out/`. The build runs in an `obs-jfmpp-builder:<distro>-<hash>` image
with the dependencies preinstalled; it is rebuilt only when `scripts/install-deps.sh` changes.
Everything worth keeping between runs stays in `_build/<distro>/`: sources, build
directories, CEF, the ccache, and the installed jellyfin-ffmpeg (`ffmpeg-prefix/`, mounted at
`/usr/lib/obs-jellyfin-ffmpeg`). So MPP, RGA and jellyfin-ffmpeg are only rebuilt when their
version, the MPP/RGA branch heads or `build-ffmpeg.sh` change, and rkaiq when its branch head,
`build-rkaiq.sh` or `patches/rkaiq` change. CI does the same with
`actions/cache`. Delete `_build/<distro>` to start from scratch.

On macOS, Colima with `--vm-type vz --mount-type virtiofs` is much faster than QEMU/sshfs.

Inside a Trixie/Resolute arm64 system or container you can run
`./scripts/build.sh` directly (uses `sudo` for apt and for creating
`/usr/lib/obs-jellyfin-ffmpeg`).

| Script | Does |
|--------|------|
| `scripts/install-deps.sh` | apt build dependencies (no distro `libav*-dev`) |
| `scripts/build-ffmpeg.sh` | Rockchip MPP + RGA, then jellyfin-ffmpeg with its patch series applied |
| `scripts/build-rkaiq.sh` | Rockchip's camera 3A engine (rkaiq) for the RK3588 ISP with `patches/rkaiq`, plus the RK3588 tuning files |
| `scripts/build-obs.sh` | applies `patches/obs-studio/<version>`, fetches and verifies CEF, builds OBS Studio against that FFmpeg, staged install |
| `scripts/package-deb.sh` | bundles FFmpeg, computes `Depends` with `dpkg-shlibdeps`, builds the `.deb` |
| `scripts/test-deb.sh` | installs the `.deb` and checks the rkmpp codecs and library resolution |
