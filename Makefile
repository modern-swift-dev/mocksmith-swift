# Override with a shell-quoted file list to check only changed Swift files.
SWIFT_FILES ?= .

.PHONY: setup lint format docs-release test-linux test-macos test-ios test-swift test test-tvos test-watchos test-all

setup:

	brew bundle install
	brew upgrade
	brew cleanup
	brew autoremove
	mint bootstrap
	lefthook install

lint: lint-workflows

	mint run --no-install realm/SwiftLint lint --config .swiftlint.yml --quiet --force-exclude $(SWIFT_FILES)

format:

	mint run --no-install nicklockwood/SwiftFormat $(SWIFT_FILES) --config .swiftformat --quiet
	mint run --no-install realm/SwiftLint lint --config .swiftlint.yml --fix --quiet --force-exclude $(SWIFT_FILES)

docs-release:

	bash Scripts/build-documentation.sh "$(VERSION)"

test-linux:
	docker run \
		--rm \
		-v "$(PWD):/workspace" \
		-w /workspace \
		swift:6.3 \
		bash -c 'swift test --scratch-path .build/linux'

test-macos:
	set -o pipefail && \
	xcodebuild test \
		-scheme Mocksmith-Package \
		-destination platform="macOS" | mint run --no-install cpisciotta/xcbeautify -q

test-ios:
	set -o pipefail && \
	xcodebuild test \
		-scheme Mocksmith-Package \
		-destination platform="iOS Simulator,name=iPhone 17 Pro,OS=26.5" | mint run --no-install cpisciotta/xcbeautify -q

test-swift:
	set -o pipefail && \
	swift test | mint run --no-install cpisciotta/xcbeautify -q

test: test-swift

test-tvos:
	set -o pipefail && \
	xcodebuild test \
		-scheme Mocksmith-Package \
		-destination platform="tvOS Simulator,name=Apple TV 4K (3rd generation),OS=26.5" | mint run --no-install cpisciotta/xcbeautify -q

test-watchos:
	set -o pipefail && \
	xcodebuild test \
		-scheme Mocksmith-Package \
		-destination platform="watchOS Simulator,name=Apple Watch Series 11 (46mm),OS=26.5" | mint run --no-install cpisciotta/xcbeautify -q

test-all: test-swift test-macos test-ios test-tvos test-watchos test-linux

.PHONY: lint-workflows

lint-workflows:
	actionlint
