# shellcheck shell=bash
# Shared settings for the obs-jfmpp build scripts. Source, don't execute.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Where jellyfin-ffmpeg (plus Rockchip MPP/RGA) is installed, both on the build
# machine and inside the final .deb. It is private to OBS: nothing else on the
# system links against it, and OBS finds it through RUNPATH.
FFMPEG_PREFIX="${FFMPEG_PREFIX:-/usr/lib/obs-jellyfin-ffmpeg}"

WORK_DIR="${WORK_DIR:-$REPO_ROOT/_build}"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/out}"
SRC_DIR="$WORK_DIR/src"

# Rockchip MPP / RGA sources, same forks and branches jellyfin-ffmpeg builds against.
RKMPP_REPO="${RKMPP_REPO:-https://github.com/nyanmisaka/rk-mirrors.git}"
RKMPP_BRANCH="${RKMPP_BRANCH:-jellyfin-mpp-next}"
RKRGA_REPO="${RKRGA_REPO:-https://github.com/nyanmisaka/rk-mirrors.git}"
RKRGA_BRANCH="${RKRGA_BRANCH:-jellyfin-rga-next}"
# Rockchip's camera 3A engine (rkaiq) for the RK3588 ISP, from an SDK mirror whose
# AIQ release (v6.0x32) matches the ISP driver ABI of the vendor 6.1/6.12 kernels.
RKAIQ_REPO="${RKAIQ_REPO:-https://github.com/mixtile-rockchip/mixtile-sdk-linux-external-camera_engine_rkaiq.git}"
RKAIQ_BRANCH="${RKAIQ_BRANCH:-linux-6.1-stan-rkr7}"

JOBS="${JOBS:-$(nproc)}"

# Compile through ccache when it's installed. The cache lives in $WORK_DIR, which
# docker-build.sh keeps on the host and CI restores with actions/cache.
CCACHE="" CMAKE_CCACHE=()
if command -v ccache >/dev/null; then
  CCACHE=ccache
  export CCACHE_DIR="${CCACHE_DIR:-$WORK_DIR/ccache}" CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-5G}"
  CMAKE_CCACHE=(-DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache)
fi

# Source checkouts may be owned by another uid (e.g. bind-mounted into a container).
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'


log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  group() { echo "::group::$*"; }
  endgroup() { echo "::endgroup::"; }
else
  group() { log "$*"; }
  endgroup() { :; }
fi

github_api() {
  local auth=()
  [[ -n "${GITHUB_TOKEN:-}" ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
  curl -fsSL "${auth[@]}" -H "Accept: application/vnd.github+json" "https://api.github.com/$1"
}

# Latest non-prerelease tag of a GitHub repo.
latest_release() {
  github_api "repos/$1/releases/latest" | jq -r .tag_name
}

# Resolve OBS_VERSION / JF_VERSION, defaulting to the latest upstream releases.
resolve_versions() {
  : "${OBS_VERSION:=$(latest_release obsproject/obs-studio)}"
  : "${JF_VERSION:=$(latest_release jellyfin/jellyfin-ffmpeg)}"
  [[ "$JF_VERSION" == v* ]] || JF_VERSION="v$JF_VERSION"
  export OBS_VERSION JF_VERSION
}

# Patch folder for an OBS version: patches/obs-studio/<version>/ holds the patch
# series refreshed against that release, and is used for every release up to the
# next folder. Picks the highest folder version <= $1.
obs_patch_dir() {
  local dir="$REPO_ROOT/patches/obs-studio" picked="" v
  for v in $(ls "$dir" | sort -V); do
    [[ -d "$dir/$v" ]] || continue
    [[ "$(printf '%s\n' "$v" "$1" | sort -V | head -n 1)" == "$v" ]] && picked="$v"
  done
  [[ -n "$picked" ]] || die "no patches for OBS $1 in $dir"
  echo "$dir/$picked"
}

# Shallow clone of a tag/branch into $SRC_DIR/<name>, reusing an existing checkout of
# the same ref and replacing one of another (e.g. after switching OBS_VERSION).
fetch_git() {
  local name="$1" repo="$2" ref="$3"; shift 3
  local dest="$SRC_DIR/$name" current remote
  if [[ -d "$dest/.git" ]]; then
    current="$(cat "$dest/.git/fetched-ref" 2>/dev/null \
      || git -C "$dest" describe --tags --exact-match 2>/dev/null \
      || git -C "$dest" rev-parse --abbrev-ref HEAD)"
    if [[ "$current" == "$ref" ]]; then
      # Tags don't move, but branches (MPP/RGA) do: refetch when the branch head
      # changed upstream. Offline, or for a tag, ls-remote finds nothing; keep it.
      remote="$(git ls-remote "$repo" "refs/heads/$ref" 2>/dev/null | cut -f1)"
      if [[ -z "$remote" || "$remote" == "$(git -C "$dest" rev-parse HEAD)" ]]; then
        log "Reusing $dest"
        return
      fi
      log "Replacing $dest: $ref moved upstream to ${remote:0:12}"
    else
      log "Replacing $dest ($current) with $ref"
    fi
    rm -rf "$dest"
  fi
  mkdir -p "$SRC_DIR"
  git clone --depth 1 --branch "$ref" "$@" "$repo" "$dest"
  echo "$ref" > "$dest/.git/fetched-ref"
}

deb_arch() { dpkg --print-architecture; }
multiarch() { dpkg-architecture -qDEB_HOST_MULTIARCH; }
codename() { . /etc/os-release; echo "${VERSION_CODENAME:?}"; }
