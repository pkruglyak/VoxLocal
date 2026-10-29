# Shared helpers for VoxLocal build scripts. Sourced, not executed.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$REPO_ROOT/vendor"
WHISPER_DIR="$VENDOR_DIR/whisper.cpp"
WHISPER_TAG="v1.9.5"
WHISPER_CLI="$WHISPER_DIR/build/bin/whisper-cli"
NEMO_SPEECH_VERSION="0.2.0"
NEMO_SPEECH_DIR="$VENDOR_DIR/nemo-speech"
NEMO_SPEECH_CLI="$NEMO_SPEECH_DIR/bin/nemo-speech"
NEMO_SPEECH_ARCHIVE="nemo-speech-$NEMO_SPEECH_VERSION-macos-aarch64-metal.tar.gz"
NEMO_SPEECH_SHA256="5cb02ba7c04f0b5585ce5cde9c830be5f0b7dfb4c83083c500109c381b4f2da9"
CMAKE_VERSION="3.30.5"
CMAKE_LOCAL_DIR="$VENDOR_DIR/tools/cmake-$CMAKE_VERSION-macos-universal"
DIST_DIR="$REPO_ROOT/dist"
APP_NAME="VoxLocal"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
MODELS_DIR="$HOME/Library/Application Support/VoxLocal/models"

log()  { printf '\033[1;34m[voxlocal]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[voxlocal:error]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

require_clt() {
  if ! xcode-select -p >/dev/null 2>&1; then
    die "Xcode Command Line Tools not found. Install them with: xcode-select --install"
  fi
  if ! command -v swift >/dev/null 2>&1; then
    die "swift not found in PATH. Install Xcode or the Command Line Tools."
  fi
}

# Locates a usable cmake: system cmake if present, otherwise the
# project-local copy downloaded by bootstrap.sh.
find_cmake() {
  if command -v cmake >/dev/null 2>&1; then
    command -v cmake
    return 0
  fi
  local local_cmake="$CMAKE_LOCAL_DIR/CMake.app/Contents/bin/cmake"
  if [[ -x "$local_cmake" ]]; then
    echo "$local_cmake"
    return 0
  fi
  return 1
}
