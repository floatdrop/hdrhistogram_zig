bench: build-c build-zig
	hyperfine "./c-recording/zig-out/bin/c_recording" "./zig-recording/zig-out/bin/zig_recording" --warmup 5 --export-markdown bench.md

build-c:
	cd c-recording && zig build && cd ..

build-zig:
	cd zig-recording && zig build && cd ..
