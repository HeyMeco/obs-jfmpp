#!/usr/bin/env bash
# Local build in a disposable arm64 container: ./scripts/docker-build.sh trixie|resolute
#
# Runs in a builder image (the distro plus install-deps.sh), rebuilt only when
# install-deps.sh changes. Everything worth keeping lives in _build/<distro> on the
# host: sources, build directories, CEF, the ccache and the installed jellyfin-ffmpeg
# (mounted at its real path, so build-ffmpeg.sh can skip an unchanged build).
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
  trixie) image=debian:trixie ;;
  resolute) image=ubuntu:resolute ;;
  *) echo "usage: $0 trixie|resolute" >&2; exit 2 ;;
esac

repo=obs-jfmpp-builder
builder="$repo:$1-$(shasum -a 256 scripts/install-deps.sh | cut -c1-12)"
if ! docker image inspect "$builder" >/dev/null 2>&1; then
  docker build --pull --platform linux/arm64 --build-arg BASE="$image" \
    -t "$builder" -f scripts/builder.Dockerfile scripts
  # Drop builder images of older install-deps.sh revisions.
  docker images --format '{{.Repository}}:{{.Tag}}' "$repo" | while read -r old; do
    [[ "$old" == "$repo:$1-"* && "$old" != "$builder" ]] && docker rmi "$old" >/dev/null || true
  done
fi

mkdir -p "_build/$1/ffmpeg-prefix"
docker run --rm --platform linux/arm64 \
  -e OBS_VERSION -e JF_VERSION -e GITHUB_TOKEN -e JOBS \
  -e WORK_DIR="/src/_build/$1" -e OUT_DIR=/src/out \
  -v "$PWD:/src" -v "$PWD/_build/$1/ffmpeg-prefix:/usr/lib/obs-jellyfin-ffmpeg" \
  -w /src "$builder" ./scripts/build.sh

# Test in a fresh container so only the package's declared dependencies are present.
deb="$(ls -t out/*_"$1"_arm64.deb | head -n1)"
docker run --rm --platform linux/arm64 -v "$PWD:/src" -w /src "$image" ./scripts/test-deb.sh "$deb"
