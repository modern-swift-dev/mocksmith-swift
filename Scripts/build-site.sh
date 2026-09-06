#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
website_dir="$repo_root/Website"
astro_output="$website_dir/dist"
docs_dir="$repo_root/.build/site"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/mocksmith-site.XXXXXX")"
staging_dir="$work_dir/docs"
backup_dir="$work_dir/previous-docs"
docs_replaced=false

cleanup() {
    if [[ "$docs_replaced" == true && ! -d "$docs_dir" && -d "$backup_dir" ]]; then
        mv "$backup_dir" "$docs_dir"
    fi
    rm -rf "$work_dir"
}
trap cleanup EXIT

if [[ ! -f "$website_dir/package.json" ]]; then
    echo "Website/package.json is missing. The Astro site must exist before building .build/site/." >&2
    exit 1
fi

npm --prefix "$website_dir" run check
npm --prefix "$website_dir" run build

if [[ ! -f "$astro_output/index.html" ]]; then
    echo "Astro did not create Website/dist/index.html." >&2
    exit 1
fi

mkdir -p "$staging_dir"
cp -R "$astro_output/." "$staging_dir/"

modules=(Mocksmith MocksmithCombine MocksmithTesting MocksmithXCTest)
slugs=(mocksmith mocksmithcombine mocksmithtesting mocksmithxctest)

for index in "${!modules[@]}"; do
    module="${modules[$index]}"
    slug="${slugs[$index]}"
    output="$staging_dir/documentation/api/$slug"
    hosting_base="docs/mocksmith-swift/documentation/api/$slug"
    mkdir -p "$(dirname "$output")"

    swift package \
        --allow-writing-to-directory "$output" \
        generate-documentation \
        --target "$module" \
        --disable-indexing \
        --transform-for-static-hosting \
        --hosting-base-path "$hosting_base" \
        --output-path "$output"

    if [[ ! -f "$output/index.html" ]]; then
        echo "DocC did not create an index for $module at $output/index.html." >&2
        exit 1
    fi
    if [[ ! -f "$output/data/documentation/$slug.json" ]]; then
        echo "DocC did not create the $module landing-page data." >&2
        exit 1
    fi
    if [[ ! -f "$output/documentation/$slug/index.html" ]]; then
        echo "DocC did not create the $module landing-page route." >&2
        exit 1
    fi
    symbol_route="$(find "$output/documentation/$slug" -mindepth 2 -type f -name 'index.html' -print -quit)"
    if [[ -z "$symbol_route" ]]; then
        echo "DocC did not create any symbol routes for $module." >&2
        exit 1
    fi
done

touch "$staging_dir/.nojekyll"
python3 "$script_dir/check-static-links.py" "$staging_dir"

mkdir -p "$(dirname "$docs_dir")"
if [[ -e "$docs_dir" ]]; then
    mv "$docs_dir" "$backup_dir"
    docs_replaced=true
fi
mv "$staging_dir" "$docs_dir"
docs_replaced=false

echo "Built GitHub Pages output at $docs_dir"
