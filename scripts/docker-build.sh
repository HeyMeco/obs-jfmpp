#!/usr/bin/env bash
# Local build in a disposable arm64 container: ./scripts/docker-build.sh trixie|resolute
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-}" in
  trixie) image=debian:trixie ;;
  resolute) image=ubuntu:resolute ;;
  *) echo "usage: $0 trixie|resolute" >&2; exit 2 ;;
esac
docker run --rm --platform linux/arm64 \
  -e OBS_VERSION -e JF_VERSION -e GITHUB_TOKEN \
  -e WORK_DIR="/src/_build/$1" -e OUT_DIR=/src/out \
  -v "$PWD:/src" -w /src "$image" ./scripts/build.sh

# Test in a fresh container so only the package's declared dependencies are present.
deb="$(ls -t out/*_"$1"_arm64.deb | head -n1)"
docker run --rm --platform linux/arm64 -v "$PWD:/src" -w /src "$image" ./scripts/test-deb.sh "$deb"

