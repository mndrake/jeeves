#!/usr/bin/env bash
# Re-vendors SQLite (amalgamation) and sqlite-vec into Sources/CSQLite.
# Pinned versions; bump deliberately and re-run the tests.
#
# Layout: include/ holds only what Swift imports (sqlite3.h plus the hand-written
# CSQLite.h). sqlite-vec.h stays next to sqlite-vec.c as a private header, because
# it would pull in sqlite3ext.h when imported without SQLITE_CORE.
# CSQLite.h and jeeves_glue.c are hand-written and are not touched by this script.
set -euo pipefail

SQLITE_YEAR=2026
SQLITE_VERSION=3540100          # 3.54.1
SQLITE_VEC_TAG=v0.1.9

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Sources/CSQLite"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Fetching SQLite $SQLITE_VERSION"
curl -sSfL -o "$WORK/sqlite.zip" "https://www.sqlite.org/$SQLITE_YEAR/sqlite-amalgamation-$SQLITE_VERSION.zip"
python3 -I -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$WORK/sqlite.zip" "$WORK"
SRC="$WORK/sqlite-amalgamation-$SQLITE_VERSION"

echo "Fetching sqlite-vec $SQLITE_VEC_TAG"
GIT_LFS_SKIP_SMUDGE=1 git -c advice.detachedHead=false clone -q --depth 1 --branch "$SQLITE_VEC_TAG" \
  https://github.com/asg017/sqlite-vec "$WORK/sqlite-vec"
VEC="$WORK/sqlite-vec"
VERSION="$(cat "$VEC/VERSION")"

mkdir -p "$DEST/include"
cp "$SRC/sqlite3.c" "$DEST/sqlite3.c"
cp "$SRC/sqlite3.h" "$DEST/include/"
cp "$VEC/sqlite-vec.c" "$DEST/sqlite-vec.c"
cp "$VEC/LICENSE-MIT" "$DEST/LICENSE-sqlite-vec-MIT"
cp "$VEC/LICENSE-APACHE" "$DEST/LICENSE-sqlite-vec-APACHE"

# Generate sqlite-vec.h from its template (same substitution as upstream's Makefile).
python3 -I - "$VEC/sqlite-vec.h.tmpl" "$DEST/sqlite-vec.h" "$VERSION" "$SQLITE_VEC_TAG" <<'PY'
import sys
tmpl, out, version, tag = sys.argv[1:]
major, minor, patch = (version.split("-")[0].split(".") + ["0", "0"])[:3]
s = open(tmpl).read()
for k, v in {"VERSION": version, "DATE": "", "SOURCE": f"github.com/asg017/sqlite-vec@{tag}",
             "VERSION_MAJOR": major, "VERSION_MINOR": minor, "VERSION_PATCH": patch}.items():
    s = s.replace("${" + k + "}", v)
open(out, "w").write(s)
PY

cat > "$DEST/VENDORED.md" <<MD
# Vendored C sources

| Component | Version | Source |
|---|---|---|
| SQLite amalgamation | $SQLITE_VERSION | https://www.sqlite.org/$SQLITE_YEAR/sqlite-amalgamation-$SQLITE_VERSION.zip |
| sqlite-vec | $VERSION ($SQLITE_VEC_TAG) | https://github.com/asg017/sqlite-vec |

SHA-256:

\`\`\`
$(cd "$DEST" && sha256sum sqlite3.c sqlite-vec.c sqlite-vec.h include/sqlite3.h)
\`\`\`

Regenerate with \`scripts/vendor-sqlite.sh\`. SQLite is public domain; sqlite-vec is MIT/Apache-2.0.
MD
echo "Vendored into $DEST"
