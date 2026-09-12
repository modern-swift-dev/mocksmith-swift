#!/usr/bin/env bash

# Rebuild the checked-in macOS generator using the selected Xcode toolchain.
# Dependency revisions are pinned by Package.resolved. This does not publish anything.
set -euo pipefail

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--check" ) ]]; then
    echo "Usage: $0 [--check]" >&2
    exit 64
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
bundle_dir="$repo_root/Tools/MocksmithGenerator.artifactbundle"

source_fingerprint() {
    (
        cd "$repo_root"
        git ls-files --cached --others --exclude-standard -- \
            Package.swift Package.resolved LICENSE Scripts/build-generator-artifact.sh \
            Sources/MocksmithGenerator Sources/MocksmithGeneration |
            LC_ALL=C sort |
            while IFS= read -r source_file; do
                shasum -a 256 "$source_file"
            done
    )
}

if [[ "${1:-}" == "--check" ]]; then
    if [[ ! -f "$bundle_dir/Sources.sha256" ]] ||
        ! cmp -s <(source_fingerprint) "$bundle_dir/Sources.sha256"; then
        echo "Generator artifact is stale; run Scripts/build-generator-artifact.sh." >&2
        exit 1
    fi
    (cd "$bundle_dir" && shasum -a 256 --check Binary.sha256)
    exit 0
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Building the macOS generator artifact requires macOS and Xcode." >&2
    exit 1
fi

mkdir -p "$repo_root/.build"
work_dir="$(mktemp -d "$repo_root/.build/generator-artifact-staging.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
staging_dir="$work_dir/MocksmithGenerator.artifactbundle"
mkdir -p "$staging_dir/bin" "$staging_dir/Licenses"
source_fingerprint > "$staging_dir/Sources.sha256"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
executables=()

for architecture in arm64 x86_64; do
    scratch_dir="$repo_root/.build/generator-artifact-$architecture"
    build_arguments=(
        --package-path "$repo_root"
        --scratch-path "$scratch_dir"
        --build-system native
        --configuration release
        --product MocksmithGenerator
        --triple "$architecture-apple-macosx13.0"
        --sdk "$sdk_path"
        --force-resolved-versions
        --disable-experimental-prebuilts
        --disable-index-store
        -Xswiftc -gnone
    )

    # Bypass the binary target so a fresh clone can bootstrap a missing artifact.
    MOCKSMITH_BUILD_GENERATOR_FROM_SOURCE=1 swift build "${build_arguments[@]}"
    bin_dir="$(MOCKSMITH_BUILD_GENERATOR_FROM_SOURCE=1 swift build \
        "${build_arguments[@]}" --show-bin-path)"
    executables+=("$bin_dir/MocksmithGenerator")
done

executable="$staging_dir/bin/MocksmithGenerator"
xcrun lipo -create "${executables[@]}" -output "$executable"
# Retain symbols required by the dynamic loader; remove debug/local symbols only.
xcrun strip -S -x "$executable"
codesign --force --sign - --timestamp=none "$executable"
for architecture in arm64 x86_64; do
    xcrun lipo "$executable" -verify_arch "$architecture"
done
codesign --verify "$executable"

cat > "$staging_dir/info.json" <<'JSON'
{
  "schemaVersion": "1.0",
  "artifacts": {
    "MocksmithGenerator": {
      "type": "executable",
      "version": "1.0.0",
      "variants": [
        {
          "path": "bin/MocksmithGenerator",
          "supportedTriples": ["arm64-apple-macosx", "x86_64-apple-macosx"]
        }
      ]
    }
  }
}
JSON

cp "$repo_root/LICENSE" "$staging_dir/LICENSE"
syntax_checkout="$repo_root/.build/generator-artifact-arm64/checkouts/swift-syntax"
cp "$syntax_checkout/LICENSE.txt" "$staging_dir/Licenses/SwiftSyntax-LICENSE.txt"
if [[ -f "$syntax_checkout/NOTICE.txt" ]]; then
    cp "$syntax_checkout/NOTICE.txt" "$staging_dir/Licenses/SwiftSyntax-NOTICE.txt"
elif [[ -f "$syntax_checkout/NOTICE" ]]; then
    cp "$syntax_checkout/NOTICE" "$staging_dir/Licenses/SwiftSyntax-NOTICE.txt"
fi

{
    echo "MocksmithGenerator macOS artifact"
    echo "Source: https://github.com/modern-swift-dev/mocksmith-swift"
    echo "Recipe: Scripts/build-generator-artifact.sh"
    echo "Configuration: Release; arm64 + x86_64; minimum macOS 13.0"
    echo "Signing: ad hoc, no timestamp"
    echo "Source revision: $(git -C "$repo_root" rev-parse HEAD)"
    echo "Sources.sha256 identifies the exact build inputs, including uncommitted edits."
    echo "SwiftSyntax revision: $(git -C "$syntax_checkout" rev-parse HEAD)"
    echo "SwiftSyntax source: https://github.com/swiftlang/swift-syntax"
    swift --version
    xcodebuild -version
    echo "macOS SDK: $(xcrun --sdk macosx --show-sdk-version)"
} > "$staging_dir/Provenance.txt"
(cd "$staging_dir" && shasum -a 256 bin/MocksmithGenerator > Binary.sha256)

if ! cmp -s <(source_fingerprint) "$staging_dir/Sources.sha256"; then
    echo "Generator sources changed during packaging; rebuild with stable inputs." >&2
    exit 1
fi

mkdir -p "$(dirname "$bundle_dir")"
if [[ -d "$bundle_dir" ]]; then
    mv "$bundle_dir" "$work_dir/previous.artifactbundle"
fi
mv "$staging_dir" "$bundle_dir"
echo "Created $bundle_dir"
file "$bundle_dir/bin/MocksmithGenerator"
xcrun otool -L "$bundle_dir/bin/MocksmithGenerator"
