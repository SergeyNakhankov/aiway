#!/bin/sh
set -eu

REPO="${AIWAY_REPO:-kirniy/aiway}"
RELEASES_API="${AIWAY_RELEASES_API:-https://api.github.com/repos/$REPO/releases?per_page=20}"
TMP_DIR="/tmp/aiway-manager-install"
SUPPORTED_ARCHES="aarch64-3.10 armv7-3.2 x64-3.2 mips-3.4 mipsel-3.4"
ARCH_CANDIDATES=""
PKG=""
URL=""
VERSION=""

fetch_text() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$1"
    return
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -qO- "$1"
    return
  fi
  echo "Need curl or wget" >&2
  exit 1
}

fetch_file() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$2" "$1"
    return
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -qO "$2" "$1"
    return
  fi
  echo "Need curl or wget" >&2
  exit 1
}

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

add_candidate() {
  case " $ARCH_CANDIDATES " in
    *" $1 "*) ;;
    *) ARCH_CANDIDATES="${ARCH_CANDIDATES}${ARCH_CANDIDATES:+ }$1" ;;
  esac
}

normalize_arch() {
  raw=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  raw=${raw%%_kn*}
  case "$raw" in
    aarch64-3.10|arm64-3.10|aarch64|arm64) echo "aarch64-3.10" ;;
    armv7sf-3.2|armv7-3.2|armv7sf|armv7) echo "armv7-3.2" ;;
    x64-3.2|x86_64-3.2|amd64-3.2|x64|x86_64|amd64) echo "x64-3.2" ;;
    mipsel-3.4|mipselsf-3.4|mipsel|mipselsf) echo "mipsel-3.4" ;;
    mips-3.4|mipssf-3.4|mipssf|mips) echo "mips-3.4" ;;
    *) return 1 ;;
  esac
}

detect_arches() {
  raw=$(opkg print-architecture 2>/dev/null || true)
  [ -n "$raw" ] || { echo "Cannot detect Keenetic architecture via opkg print-architecture" >&2; exit 1; }

  for name in $(printf '%s\n' "$raw" | awk '$1=="arch"{print $3+0, $2}' | sort -nr | awk '{print $2}'); do
    normalized=$(normalize_arch "$name" 2>/dev/null || true)
    [ -n "$normalized" ] && add_candidate "$normalized"
  done

  [ -n "$ARCH_CANDIDATES" ] || {
    echo "Unsupported Keenetic architecture. Supported package targets: $SUPPORTED_ARCHES" >&2
    echo "opkg print-architecture output:" >&2
    printf '%s\n' "$raw" >&2
    exit 1
  }
}

extract_asset_urls() {
  printf '%s' "$1" | sed 's/"browser_download_url"/\
"browser_download_url"/g' | sed -n 's#.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*#\1#p'
}

find_package() {
  releases=$(fetch_text "$RELEASES_API")
  asset_urls=$(extract_asset_urls "$releases")
  [ -n "$asset_urls" ] || {
    echo "Cannot find any release assets in $RELEASES_API" >&2
    exit 1
  }

  for arch in $ARCH_CANDIDATES; do
    url=$(
      printf '%s\n' "$asset_urls" | awk -v suffix="_${arch}-kn.ipk" 'index($0, suffix) { print; exit }'
    )
    [ -n "$url" ] || continue
    URL="$url"
    PKG=${url##*/}
    VERSION=$(printf '%s' "$PKG" | sed -n 's/^aiway-manager_\([^_]*\)_.*/\1/p')
    ARCH="$arch"
    return 0
  done

  echo "No compatible release package found for Keenetic architectures: $ARCH_CANDIDATES" >&2
  echo "Supported package targets: $SUPPORTED_ARCHES" >&2
  exit 1
}

install_pkg() {
  mkdir -p "$TMP_DIR"
  fetch_file "$URL" "$TMP_DIR/$PKG"
  opkg install "$TMP_DIR/$PKG"
}

detect_arches
find_package
install_pkg
