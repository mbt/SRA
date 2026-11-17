.PHONY: harness sizes ios test clean

# Default: build all four harness binaries (ReleaseSmall, stripped).
harness:
	scripts/build-harness.sh

sizes:
	scripts/size-report.sh

# Regenerate the Xcode project (requires xcodegen).
ios:
	cd ios && xcodegen generate

# Zig unit tests for the harness.
test:
	cd harness && zig build test

clean:
	rm -rf dist harness/zig-out harness/.zig-cache
