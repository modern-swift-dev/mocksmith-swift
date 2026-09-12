# Contributing to Mocksmith

## Updating the generator

The macOS build plugin uses the universal executable in `Tools/MocksmithGenerator.artifactbundle`. After changing `Sources/MocksmithGenerator`, `Sources/MocksmithGeneration`, or their pinned dependencies, rebuild and verify it with the selected Xcode toolchain:

```bash
Scripts/build-generator-artifact.sh
Scripts/build-generator-artifact.sh --check
python3 Scripts/test-generator.py Tools/MocksmithGenerator.artifactbundle/bin/MocksmithGenerator
python3 Scripts/test-xcode-build-cache.py
```

Commit the rebuilt artifact with its source changes. The bundle records source hashes, dependency revisions, compiler information, and licenses. CI checks for stale artifacts. The packaging script bootstraps from source even when the bundle does not exist.

For generator development without rebuilding the artifact, use `MOCKSMITH_BUILD_GENERATOR_FROM_SOURCE=1 swift build --product MocksmithGenerator` and pass that executable to `Scripts/test-generator.py`. This opt-in also uses the original build-command plugin path; do not set it for normal Xcode builds when checking cache performance. Linux builds continue to build the tool from source automatically.

## Publishing the site

Guides and examples live in [Documentation/Site](Documentation/Site). The [central documentation repository](https://github.com/modern-swift-dev/docs) owns the shared Astro theme, builds the guides and DocC API reference, and publishes them daily. For local builds and previews, follow the [docs README](https://github.com/modern-swift-dev/docs/blob/main/README.md).

Keep Markdown guides, example source, and Swift documentation comments in this module. Publish a GitHub release to update the version and release information on the next daily build. Commit documentation sources only.
