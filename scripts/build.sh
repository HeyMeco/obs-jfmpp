#!/usr/bin/env bash
# Full pipeline: deps -> rkmpp/rga/jellyfin-ffmpeg -> rkaiq -> OBS -> .deb.
# Env: OBS_VERSION (e.g. 32.2.2), JF_VERSION (e.g. v8.1.3-1); default = latest.
source "$(dirname "$0")/common.sh"
"$REPO_ROOT/scripts/install-deps.sh"
# Re-source: ccache may have just been installed.
source "$REPO_ROOT/scripts/common.sh"
[[ -z "$CCACHE" ]] || ccache -z >/dev/null
resolve_versions
log "OBS Studio $OBS_VERSION + jellyfin-ffmpeg $JF_VERSION on $(codename)/$(deb_arch)"
"$REPO_ROOT/scripts/build-ffmpeg.sh"
"$REPO_ROOT/scripts/build-rkaiq.sh"
"$REPO_ROOT/scripts/build-obs.sh"
"$REPO_ROOT/scripts/package-deb.sh"
[[ -z "$CCACHE" ]] || ccache -s
