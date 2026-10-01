#!/bin/bash
# Fetch linuxdeploy and the AppImage runtime. From GSXFormsKit's
# Scripts/install-linuxdeploy.sh.
#
# linuxdeploy is itself an AppImage and is extracted rather than run: mounting
# one needs FUSE, which a container may not have, and extracting sidesteps the
# question entirely.
#
# A release, not continuous: a build that moves under the job breaks it with
# nothing changed here (LINUXDEPLOY_RELEASE=continuous for the newest). It
# goes where the caller can write, without sudo, and is run once here, so that
# one that cannot run says why here rather than at packaging.
set -euo pipefail

dest=${LINUXDEPLOY_DIR:-${RUNNER_TEMP:-/tmp}/linuxdeploy}
release=${LINUXDEPLOY_RELEASE:-1-alpha-20251107-1}
runtime_dir=${APPIMAGE_RUNTIME_DIR:-/tmp/appimage-runtime}
arch=$(uname -m)

if ! "$dest/AppRun" --version > /dev/null 2>&1; then
  work=$(mktemp -d)
  curl -fsSL -o "$work/linuxdeploy.AppImage" \
    "https://github.com/linuxdeploy/linuxdeploy/releases/download/${release}/linuxdeploy-${arch}.AppImage"
  chmod +x "$work/linuxdeploy.AppImage"
  (cd "$work" && ./linuxdeploy.AppImage --appimage-extract > /dev/null)
  if [ -e "$dest" ]; then chmod -R u+rwX "$dest" 2> /dev/null || true; rm -rf "$dest"; fi
  mkdir -p "$(dirname "$dest")"
  mv "$work/squashfs-root" "$dest"
  rm -rf "$work"
  chmod -R u+rwX,go+rX "$dest"
fi

if ! version=$("$dest/AppRun" --version 2>&1); then
  echo "linuxdeploy at $dest does not run: $version" >&2
  ls -la "$dest" "$dest/usr/bin" >&2 || true
  file -L "$dest/AppRun" >&2 || true
  findmnt -T "$dest" -o TARGET,OPTIONS >&2 || true
  exit 1
fi

mkdir -p "$runtime_dir"
if [ ! -s "$runtime_dir/runtime-$arch" ]; then
  curl -fsSL -o "$runtime_dir/runtime-$arch" \
    "https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-${arch}"
fi
echo "linuxdeploy: $dest/AppRun (${version##*$'\n'})"
echo "runtime:     $runtime_dir/runtime-$arch"
