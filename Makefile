.PHONY: build build-ios test test-core lint format coverage coverage-baseline clean

build:
	swift build

test:
	swift test

# Ticket 13: pre-commit runs format + Core unit tests only, never the full suite.
test-core:
	swift test --filter CoreTests

# The toolchain-bundled formatter, so local and CI share one version.
build-ios:
	@# The shared app layer must compile for iOS, not only for the host. The server
	@# and CLI targets are macOS-only and are not part of this scheme.
	xcodebuild -scheme AppCore -destination 'generic/platform=iOS' build | tail -3

lint:
	swift format lint --recursive --strict Sources Tests

format:
	swift format format --in-place --recursive Sources Tests

coverage:
	swift test --enable-code-coverage
	python3 Scripts/check-coverage.py

# Bump the recorded baseline deliberately, after adding tests.
coverage-baseline:
	swift test --enable-code-coverage
	python3 Scripts/check-coverage.py --update-baseline

clean:
	rm -rf .build
