# Contributing to Mocksmith

## Publishing the site

The documentation sources remain in this repository. The [central documentation repository](https://github.com/modern-swift-dev/docs) builds and publishes them daily at [the module documentation site](https://modern-swift-dev.github.io/docs/mocksmith-swift/). Publish a GitHub release to update the release information on the next scheduled build; publishing is configured in the central repository.

To build and review documentation locally:

```sh
make site-install
make site-build
make site-validate
make site-preview
```

The build fetches the latest published release, builds the Astro pages and static DocC reference, and checks internal links. Generated HTML is written to `.build/site/` and is ignored by Git. Commit documentation source changes only.
