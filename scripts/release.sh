#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"

if [[ -z "$VERSION" ]]; then
    echo "Usage: bash scripts/release.sh VERSION" >&2
    echo "Example: bash scripts/release.sh 1.0.0" >&2
    exit 1
fi

TAG="v${VERSION}"
ZIP="$ROOT/CursorBar-${VERSION}.zip"

cd "$ROOT"

if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Working tree is not clean. Commit or stash changes first." >&2
    exit 1
fi

echo "Building CursorBar ${VERSION}..."
VERSION="$VERSION" bash scripts/package.sh

echo "Creating ${ZIP}..."
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent CursorBar.app "$ZIP"
shasum -a 256 "$ZIP"

echo "Tagging ${TAG}..."
git tag -a "$TAG" -m "Release ${TAG}"

echo
echo "Next steps:"
echo "  git push origin main"
echo "  git push origin ${TAG}"
echo
echo "Or publish locally:"
echo "  gh release create ${TAG} ${ZIP} --title ${TAG} --generate-notes"
