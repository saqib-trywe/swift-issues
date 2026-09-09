.PHONY: build test lint format coverage clean

build:
	swift build

test:
	swift test

# Ticket 13: pre-commit runs format + Core unit tests only, never the full suite.
test-core:
	swift test --filter CoreTests

lint:
	swift-format lint --recursive --strict Sources Tests

format:
	swift-format format --in-place --recursive Sources Tests

coverage:
	swift test --enable-code-coverage

clean:
	rm -rf .build
