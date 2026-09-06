.PHONY: setup lint format docs-release test-linux test-macos test-ios test-swift test test-tvos test-watchos test-all

setup:

	brew bundle install
	brew upgrade
	brew cleanup
	brew autoremove
	mint bootstrap
	lefthook install

lint:

	mint run --no-install realm/SwiftLint  --config .swiftlint.yml --quiet

format:

	mint run --no-install nicklockwood/SwiftFormat . --config .swiftformat --quiet
	mint run --no-install realm/SwiftLint  --config .swiftlint.yml --fix --quiet

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
