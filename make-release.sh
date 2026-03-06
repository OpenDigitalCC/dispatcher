#!/bin/bash
# make-release.sh - Create a versioned release tarball and CycloneDX SBOM
#
# Usage: ./make-release.sh
#
# Reads version from VERSION file. Requires a clean git working tree.
# Produces:
#   dispatcher-<version>.tar.gz
#   sbom.json  (CycloneDX 1.6 JSON, committed to repo)

set -euo pipefail

# --- helpers ---

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# --- version ---

VERSION_FILE="VERSION"
[[ -f "$VERSION_FILE" ]] || die "VERSION file not found."
VERSION=$(cat "$VERSION_FILE" | tr -d '[:space:]')
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "VERSION must be semver n.n.n, got: $VERSION"

info "Release version: $VERSION"

# --- git checks ---

if ! git rev-parse --git-dir &>/dev/null; then
    die "Not a git repository."
fi

if ! git diff --quiet || ! git diff --cached --quiet; then
    die "Working tree has uncommitted changes. Commit or stash before releasing."
fi

COMMIT=$(git rev-parse HEAD)
info "Git commit: $COMMIT"

# --- paths ---

RELEASE_NAME="dispatcher-${VERSION}"
TARBALL="${RELEASE_NAME}.tar.gz"
STAGE_DIR=$(mktemp -d)
STAGE="${STAGE_DIR}/${RELEASE_NAME}"
trap 'rm -rf "$STAGE_DIR"' EXIT

# --- files to ship ---

SHIP_FILES=(
    bin/dispatcher
    bin/dispatcher-agent
    bin/dispatcher-api
    install.sh
    VERSION
    LICENCE
    README.md
    INSTALL.md
    DOCKER.md
    SECURITY.md
    DEVELOPER.md
    BACKGROUND.md
)

SHIP_DIRS=(
    lib
    etc
    t
)

# --- stage files ---

info "Staging files..."
mkdir -p "$STAGE"

for f in "${SHIP_FILES[@]}"; do
    [[ -f "$f" ]] || die "Expected file not found: $f"
    mkdir -p "$STAGE/$(dirname "$f")"
    cp "$f" "$STAGE/$f"
done

for d in "${SHIP_DIRS[@]}"; do
    [[ -d "$d" ]] || die "Expected directory not found: $d"
    cp -r "$d" "$STAGE/"
done

# --- stamp version in the three binaries ---

info "Stamping version $VERSION in binaries..."
chmod 755 "$STAGE/install.sh"
for bin in dispatcher dispatcher-agent dispatcher-api; do
    sed -i "s/our \$VERSION = .*/our \$VERSION = '$VERSION';/" \
        "$STAGE/bin/$bin"
done

# --- generate sbom.json ---

info "Generating CycloneDX SBOM..."

# Collect source components with SHA-256 hashes
# Components: the three binaries and all library modules

collect_components() {
    local components="[]"

    # bin/ executables
    for bin in dispatcher dispatcher-agent dispatcher-api; do
        local path="bin/$bin"
        local staged="$STAGE/bin/$bin"
        local hash
        hash=$(sha256sum "$staged" | awk '{print $1}')
        local component
        component=$(python3 -c "
import json, sys
c = {
    'type': 'file',
    'name': '$bin',
    'version': '$VERSION',
    'hashes': [{'alg': 'SHA-256', 'content': '$hash'}],
    'licenses': [{'license': {'id': 'AGPL-3.0-only'}}],
    'purl': 'pkg:generic/opendigital/dispatcher-$bin@$VERSION'
}
print(json.dumps(c))
")
        components=$(python3 -c "
import json, sys
comps = json.loads('$components' if '$components' != '[]' else '[]')
comps.append(json.loads(sys.stdin.read()))
print(json.dumps(comps))
" <<< "$component")
    done

    # lib/ modules
    while IFS= read -r -d '' pm; do
        local rel="${pm#$STAGE/}"
        local name
        name=$(echo "$rel" | sed 's|lib/||; s|/|::|g; s|\.pm$||')
        local hash
        hash=$(sha256sum "$pm" | awk '{print $1}')
        local component
        component=$(python3 -c "
import json
c = {
    'type': 'library',
    'name': '$name',
    'version': '$VERSION',
    'hashes': [{'alg': 'SHA-256', 'content': '$hash'}],
    'licenses': [{'license': {'id': 'AGPL-3.0-only'}}],
    'purl': 'pkg:generic/opendigital/$name@$VERSION'
}
print(json.dumps(c))
")
        components=$(python3 -c "
import json, sys
comps = json.loads('''$components''')
comps.append(json.loads(sys.stdin.read()))
print(json.dumps(comps))
" <<< "$component")
    done < <(find "$STAGE/lib" -name '*.pm' -print0 | sort -z)

    echo "$components"
}

SOURCE_COMPONENTS=$(collect_components)

# Dependency components - OS-managed, versions resolved at install time
DEPS_JSON=$(python3 -c "
import json

deps = [
    {
        'type': 'library',
        'name': 'IO::Socket::SSL',
        'version': 'unknown',
        'description': 'TLS sockets. Debian: libio-socket-ssl-perl, Alpine: perl-io-socket-ssl',
        'externalReferences': [
            {'type': 'distribution', 'url': 'https://packages.debian.org/trixie/libio-socket-ssl-perl'},
            {'type': 'distribution', 'url': 'https://pkgs.alpinelinux.org/package/edge/main/x86_64/perl-io-socket-ssl'},
        ]
    },
    {
        'type': 'library',
        'name': 'JSON',
        'version': 'unknown',
        'description': 'JSON encode/decode. Debian: libjson-perl, Alpine: perl-json',
        'externalReferences': [
            {'type': 'distribution', 'url': 'https://packages.debian.org/trixie/libjson-perl'},
            {'type': 'distribution', 'url': 'https://pkgs.alpinelinux.org/package/edge/main/x86_64/perl-json'},
        ]
    },
    {
        'type': 'library',
        'name': 'LWP::UserAgent',
        'version': 'unknown',
        'description': 'HTTP client. Debian: libwww-perl, Alpine: perl-libwww',
        'externalReferences': [
            {'type': 'distribution', 'url': 'https://packages.debian.org/trixie/libwww-perl'},
            {'type': 'distribution', 'url': 'https://pkgs.alpinelinux.org/package/edge/main/x86_64/perl-libwww'},
        ]
    },
    {
        'type': 'library',
        'name': 'perl',
        'version': 'unknown',
        'description': 'Perl runtime and core modules. Debian: perl, Alpine: perl',
        'externalReferences': [
            {'type': 'distribution', 'url': 'https://packages.debian.org/trixie/perl'},
            {'type': 'distribution', 'url': 'https://pkgs.alpinelinux.org/package/edge/main/x86_64/perl'},
        ]
    },
    {
        'type': 'library',
        'name': 'openssl',
        'version': 'unknown',
        'description': 'Key, CSR, and certificate operations. Debian: openssl, Alpine: openssl',
        'externalReferences': [
            {'type': 'distribution', 'url': 'https://packages.debian.org/trixie/openssl'},
            {'type': 'distribution', 'url': 'https://pkgs.alpinelinux.org/package/edge/main/x86_64/openssl'},
        ]
    },
]

print(json.dumps(deps, indent=2))
")

TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
SERIAL="urn:uuid:$(python3 -c "import uuid; print(uuid.uuid4())")"

python3 -c "
import json, sys

source = json.loads(sys.argv[1])
deps   = json.loads(sys.argv[2])

sbom = {
    'bomFormat': 'CycloneDX',
    'specVersion': '1.6',
    'serialNumber': '$SERIAL',
    'version': 1,
    'metadata': {
        'timestamp': '$TIMESTAMP',
        'tools': [{'name': 'make-release.sh', 'version': '$VERSION'}],
        'component': {
            'type': 'application',
            'name': 'dispatcher',
            'version': '$VERSION',
            'description': 'Perl mTLS remote script execution system',
            'licenses': [{'license': {'id': 'AGPL-3.0-only'}}],
            'externalReferences': [
                {'type': 'vcs', 'url': 'https://github.com/OpenDigitalCC/dispatcher'},
            ]
        }
    },
    'components': source + deps
}

print(json.dumps(sbom, indent=2))
" "$SOURCE_COMPONENTS" "$DEPS_JSON" > sbom.json

info "sbom.json written ($(wc -l < sbom.json) lines)"

# Copy sbom into the staged release too
cp sbom.json "$STAGE/sbom.json"

# --- create tarball ---

info "Creating tarball: $TARBALL"
tar -czf "$TARBALL" -C "$STAGE_DIR" "$RELEASE_NAME"

TARBALL_HASH=$(sha256sum "$TARBALL" | awk '{print $1}')
info "SHA-256: $TARBALL_HASH"
echo "$TARBALL_HASH  $TARBALL" > "${TARBALL}.sha256"

# --- git tag ---

TAG="v${VERSION}"
if git rev-parse "$TAG" &>/dev/null 2>&1; then
    warn "Tag $TAG already exists - skipping tag creation."
else
    git tag -a "$TAG" -m "Release $VERSION"
    info "Tagged: $TAG"
fi

# --- bump patch version for next release ---

MAJOR=$(echo "$VERSION" | cut -d. -f1)
MINOR=$(echo "$VERSION" | cut -d. -f2)
PATCH=$(echo "$VERSION" | cut -d. -f3)
NEXT_VERSION="${MAJOR}.${MINOR}.$((PATCH + 1))"
echo "$NEXT_VERSION" > VERSION
info "VERSION bumped to $NEXT_VERSION for next release."

# --- summary ---

echo ""
echo "================================================================"
echo " Release $VERSION complete"
echo "================================================================"
echo ""
echo "  Tarball:   $TARBALL"
echo "  Checksum:  ${TARBALL}.sha256"
echo "  SBOM:      sbom.json"
echo "  Tag:       $TAG  ($COMMIT)"
echo "  Next ver:  $NEXT_VERSION"
echo ""
echo "Next steps:"
echo ""
echo "  1. Review sbom.json and commit it alongside the bumped VERSION:"
echo "       git add sbom.json VERSION && git commit -m 'release: $VERSION'"
echo ""
echo "  2. Push commits and tag:"
echo "       git push && git push origin $TAG"
echo ""
echo "  3. Create a GitHub release at:"
echo "       https://github.com/OpenDigitalCC/dispatcher/releases/new"
echo "       Tag:    $TAG"
echo "       Title:  Dispatcher $VERSION"
echo "       Assets: $TARBALL"
echo "               ${TARBALL}.sha256"
echo ""
echo "  4. Verify the release:"
echo "       https://github.com/OpenDigitalCC/dispatcher/releases/tag/$TAG"
echo ""
echo "================================================================"
