#!/usr/bin/env bash
#
# Build an agentc Toolkit bundle from scripts/toolkit/manifest.sh.
#
#   ./scripts/toolkit/build-toolkit.sh                     # host architecture
#   ./scripts/toolkit/build-toolkit.sh --arch arm64
#   ./scripts/toolkit/build-toolkit.sh --output /tmp/out
#
# Produces <output>/agentc-toolkit-<arch>-linux-static.tar.gz. Every download is
# verified against the digest pinned in the manifest before anything is unpacked,
# and the archive is written deterministically, so the same manifest always
# yields byte-identical output.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=manifest.sh
source "$script_dir/manifest.sh"

arch=""
output="dist"

while [ $# -gt 0 ]; do
  case "$1" in
    --arch) arch="${2:-}"; shift 2 ;;
    --output) output="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^#\{1,2\} \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$arch" ]; then
  case "$(uname -m)" in
    x86_64|amd64) arch=x64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo "unsupported host architecture: $(uname -m); pass --arch" >&2; exit 2 ;;
  esac
fi

case "$arch" in
  x64|arm64) ;;
  *) echo "unsupported architecture: $arch (expected x64 or arm64)" >&2; exit 2 ;;
esac

# GNU tar for --sort/--mtime; bsdtar cannot write a reproducible archive.
tar_bin=tar
if ! tar --version 2>/dev/null | grep -q GNU; then
  if command -v gtar >/dev/null 2>&1; then
    tar_bin=gtar
  else
    echo "GNU tar is required (macOS: brew install gnu-tar)" >&2
    exit 1
  fi
fi

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
root="$work/toolkit"
mkdir -p "$root"

contents_manifest="$work/contents"
: > "$contents_manifest"

while IFS='|' read -r dest entry_arch url digest member; do
  [ -n "$dest" ] || continue
  case "$dest" in \#*) continue ;; esac
  [ "$entry_arch" = "$arch" ] || [ "$entry_arch" = any ] || continue

  case "$url" in
    https://*) ;;
    *) echo "refusing non-https source for $dest: $url" >&2; exit 1 ;;
  esac

  echo "==> $dest  <-  $url"
  download="$work/download"
  rm -rf "$download"; mkdir -p "$download"
  file="$download/$(basename "$url")"
  curl -fsSL --proto '=https' --tlsv1.2 -o "$file" "$url"

  actual="$(sha256 "$file")"
  if [ "$actual" != "$digest" ]; then
    echo "checksum mismatch for $url" >&2
    echo "  expected $digest" >&2
    echo "  actual   $actual" >&2
    exit 1
  fi

  mkdir -p "$root/$(dirname "$dest")"
  if [ "$member" = "-" ]; then
    cp "$file" "$root/$dest"
  else
    # Unpack only the named member, and only after the digest checked out.
    case "$file" in
      *.tar.gz|*.tgz) "$tar_bin" xzf "$file" -C "$download" "$member" ;;
      *.tar.xz) "$tar_bin" xJf "$file" -C "$download" "$member" ;;
      *) echo "don't know how to extract from $file" >&2; exit 1 ;;
    esac
    cp "$download/$member" "$root/$dest"
  fi

  case "$dest" in
    bin/*) chmod 0755 "$root/$dest" ;;
    *) chmod 0644 "$root/$dest" ;;
  esac
  printf '%s  %s\n' "$(sha256 "$root/$dest")" "$dest" >> "$contents_manifest"
done <<< "$TOOLKIT_CONTENTS"

# Shipped inside the bundle so an installed toolkit says what it is.
{
  echo "agentc Toolkit v$TOOLKIT_VERSION ($arch)"
  echo
  cat "$contents_manifest"
} > "$root/TOOLKIT"
chmod 0644 "$root/TOOLKIT"

mkdir -p "$output"
output="$(cd "$output" && pwd)"
archive="$output/agentc-toolkit-$arch-linux-static.tar.gz"

# Fixed ordering, timestamps and ownership, and gzip without its own mtime, so
# an unchanged manifest reproduces the same bytes.
(cd "$root" && "$tar_bin" --sort=name --mtime='@0' --owner=0 --group=0 \
  --numeric-owner --format=gnu -cf - .) | gzip -9n > "$archive"

echo
echo "built $archive"
echo "  $(sha256 "$archive")"
