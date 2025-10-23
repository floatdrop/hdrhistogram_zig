bench: build-c build-zig
	hyperfine "./bench/c-recording/zig-out/bin/c_recording" "./bench/zig-recording/zig-out/bin/zig_recording" --warmup 100 --export-markdown bench.md

build-c:
	cd bench/c-recording && zig build --release=fast && cd ../..

build-zig:
	cd bench/zig-recording && zig build --release=fast && cd ../..
