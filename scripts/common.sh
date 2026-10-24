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

JOBS="${JOBS:-$(nproc)}"

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

# Shallow clone of a tag/branch into $SRC_DIR/<name>, reusing an existing checkout.
fetch_git() {
  local name="$1" repo="$2" ref="$3"; shift 3
  local dest="$SRC_DIR/$name"
  if [[ -d "$dest/.git" ]]; then
    log "Reusing $dest"
    return
  fi
  mkdir -p "$SRC_DIR"
  git clone --depth 1 --branch "$ref" "$@" "$repo" "$dest"
}

deb_arch() { dpkg --print-architecture; }
multiarch() { dpkg-architecture -qDEB_HOST_MULTIARCH; }
codename() { . /etc/os-release; echo "${VERSION_CODENAME:?}"; }
