#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

version="$(sed -n 's:.*<key>CFBundleShortVersionString</key><string>\(.*\)</string>.*:\1:p' build.sh)"
tag="v$version"
notes="$(awk -v v="## $version" '$0 == v { on = 1; next } /^## / { on = 0 } on' CHANGELOG.md | sed -e '/./,$!d')"

[ -n "$version" ] || { echo "no version in build.sh" >&2; exit 1; }
[ -n "$notes" ] || { echo "CHANGELOG.md has no section for $version" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "commit your changes first, the release is cut from HEAD" >&2; exit 1; }
if gh release view "$tag" >/dev/null 2>&1; then
    echo "$tag is already released, bump the version in build.sh" >&2
    exit 1
fi

./build.sh
git push origin HEAD
gh release create "$tag" build/Niche.dmg --target "$(git rev-parse HEAD)" --title "$tag" --notes "$notes"
