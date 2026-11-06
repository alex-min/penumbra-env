#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
pmaports=${PMAPORTS_DIR:-$repo_root/../pmaports}
aport=$pmaports/temp/penumbra-env
apkbuild=$aport/APKBUILD
[[ -f $apkbuild ]] || { echo "Missing $apkbuild" >&2; exit 1; }

# Snapshot committed sources, including Cargo.lock, without host build artifacts.
git -C "$repo_root" diff --quiet HEAD -- || {
    echo 'Commit Penumbra source changes before building the snapshot.' >&2
    exit 1
}
git -C "$pmaports" diff --quiet HEAD -- temp/penumbra-env || {
    echo 'Commit changes to temp/penumbra-env before refreshing its snapshot.' >&2
    exit 1
}
head=$(git -C "$repo_root" rev-parse --short HEAD)
snapshot=$(mktemp "$aport/.snapshot.XXXXXXXX")
trap 'rm -f "$snapshot"' EXIT
git -C "$repo_root" archive --format=tar --prefix=penumbra-env-jflte/ HEAD | gzip -n > "$snapshot"
mv "$snapshot" "$aport/penumbra-env-jflte.tar.gz"
sum=$(sha512sum "$aport/penumbra-env-jflte.tar.gz")
sum=${sum%% *}
pkgrel=$(sed -n 's/^pkgrel=//p' "$apkbuild")
[[ $pkgrel =~ ^[0-9]+$ ]] || { echo 'Invalid pkgrel' >&2; exit 1; }
sed -i -e "s/^pkgrel=.*/pkgrel=$((pkgrel + 1))/" \
    -e "s/^.*  penumbra-env-jflte.tar.gz\$/$sum  penumbra-env-jflte.tar.gz/" "$apkbuild"
git -C "$pmaports" add -- temp/penumbra-env/APKBUILD temp/penumbra-env/penumbra-env-jflte.tar.gz
git -C "$pmaports" commit -m "temp/penumbra-env: snapshot Penumbra $head" >&2
pmbootstrap build --lax --arch armv7 penumbra-env --force >&2
