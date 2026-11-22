# FlowDroid build entry points. Tools: Node 22+, Rust (rustup), cargo-ndk,
# rust-anything, Flutter, JDK 17 and the Android SDK/NDK (see README).

CORE      := core
APP       := app
BRIDGE    := $(abspath $(CORE)/flowcore)
JNI_LIBS  := $(APP)/android/app/src/main/jniLibs
ABIS      := -t arm64-v8a -t armeabi-v7a -t x86_64

.PHONY: all check ts-test core-test core-lint port-verify android-libs host-lib app-test app-lint apk icons clean

all: check apk

## Everything CI runs.
check: ts-test core-lint core-test port-verify app-lint app-test

## TypeScript reference engine: type-check and tests.
ts-test:
	cd engine-ts && npx tsc -p . && node --test 'test/*.test.ts'

core-test:
	cd $(CORE) && cargo test --workspace

core-lint:
	cd $(CORE) && cargo fmt --all --check && cargo clippy --workspace --all-targets -- -D warnings

## Re-record the TypeScript behavior and prove the Rust port still matches it.
port-verify:
	cd engine-ts && node scripts/gen-cases.ts > $(BRIDGE)/inputs.jsonl
	cd engine-ts && rust-anything record $(BRIDGE) --inputs $(BRIDGE)/inputs.jsonl --from-tests -- node --test 'test/*.test.ts'
	rust-anything build $(BRIDGE)
	rust-anything diff $(BRIDGE)
	rust-anything gate $(BRIDGE)

## The core for each Android ABI, into the app's jniLibs.
android-libs:
	./scripts/fetch-proot.sh $(JNI_LIBS)
	cd $(CORE) && cargo ndk $(ABIS) -P 24 -o ../$(JNI_LIBS) build --release -p flowcore-ffi

## The core for this machine, used by `flutter test`.
host-lib:
	cd $(CORE) && cargo build --release -p flowcore-ffi

app-lint:
	cd $(APP) && dart format --set-exit-if-changed lib test && flutter analyze

app-test: host-lib
	cd $(APP) && flutter test

## Rebuild the icon font and lib/ui/icons.dart from scripts/icons/build_icons.py
## (needs: pip install fonttools picosvg skia-pathops).
icons:
	python3 scripts/icons/build_icons.py

apk: android-libs
	cd $(APP) && flutter build apk --release

clean:
	cd $(CORE) && cargo clean
	cd $(APP) && flutter clean
