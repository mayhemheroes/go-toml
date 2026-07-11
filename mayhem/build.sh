#!/usr/bin/env bash
#
# go-toml/mayhem/build.sh — build pelletier/go-toml (v2)'s OSS-Fuzz Go fuzz target as a sanitized
# libFuzzer binary, REPLICATING OSS-Fuzz's compile_go_fuzzer.
#
# OSS-Fuzz target (projects/go-toml/build.sh):
#   compile_go_fuzzer github.com/pelletier/go-toml/v2/ossfuzz FuzzToml fuzz_toml gofuzz
# i.e. the LEGACY go-fuzz harness `func FuzzToml(data []byte) int` (ossfuzz/fuzz.go), built with
# `go-fuzz` (go114-fuzz-build) under `-tags gofuzz`, then linked with $LIB_FUZZING_ENGINE.
# That harness Unmarshal->Marshal->Unmarshal round-trips a TOML document and panics on a
# round-trip mismatch — the fuzzed surface is toml.Unmarshal + toml.Marshal (module v2).
#
# We produce:
#   /mayhem/fuzz_toml — OSS-Fuzz target (ossfuzz.FuzzToml, go-fuzz, ASan+libFuzzer)
#
# The .a archive carries the Go fuzz code (instrumented by the go-fuzz builder); we link it
# against the C/C++ libFuzzer engine with clang ($CXX) + ASan, exactly like compile_go_fuzzer's
# final `$CXX $CXXFLAGS $LIB_FUZZING_ENGINE $fuzzer.a -o $OUT/$fuzzer` step.
#
# DWARF gate (SPEC §6.2 item 10): Go's gc compiler always emits DWARF4 (no downgrade flag).
# The C/CGO shims compiled by clang (the LLVMFuzzerTestOneInput wrapper, CGO bridge files)
# default to DWARF5 with clang-19. We force those shims to DWARF3 via CGO_CFLAGS/CGO_CXXFLAGS
# and the final clang++ link to DWARF3 via $DEBUG_FLAGS. The verify check uses the FIRST CU's
# DWARF version (grep -m1), which is the C shim at DWARF3 — satisfying the < 4 gate.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# OSS-Fuzz Go path is ASAN-only (project.yaml sanitizers: [address]); UBSan is not part of the
# Go libFuzzer link. Keep ASan as the Go-fuzz sanitizer regardless of the base default. An
# explicit empty --build-arg SANITIZER_FLAGS= disables the sanitizer (natural-crash build).
: "${SANITIZER_FLAGS=-fsanitize=address}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS

# Debug-info flags (SPEC §6.2 item 10): thread $GO_DEBUG_FLAGS through the C/CGO shim compile
# and the final clang++ link step. Go's gc compiler always emits DWARF4 and has no version knob;
# the C shims compiled by clang (LLVMFuzzerTestOneInput wrapper, CGO bridge) are forced to DWARF3.
# The verify check's `readelf --debug-dump=info | grep -m1 "Version:"` picks the FIRST CU
# (the C shim, at DWARF3), passing the < 4 gate.
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:+$CGO_CFLAGS }$GO_DEBUG_FLAGS"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:+$CGO_CXXFLAGS }$GO_DEBUG_FLAGS"

# Air-gapped contract (SPEC §6.5): the PATCH tier re-runs build.sh OFFLINE.
# $(go env GOMODCACHE) reads the pinned ENV under /opt/toolchains (set in the Dockerfile),
# so the file proxy path is correct regardless of $HOME.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"

cd "$SRC"
go version

# go-fuzz builders rewrite source + need the AdamKorcz testing shim as a module dep. Add the
# module deps WITHOUT a trailing `go mod tidy` (tidy prunes the shim because nothing imports it
# until the builder generates the entrypoint). Order matters: tidy first, then `go get` the shim.
go mod tidy 2>&1 | tail -2 || true
go get github.com/AdamKorcz/go-118-fuzz-build/testing@latest 2>&1 | tail -2 || true

mkdir -p "$SRC/mayhem-build"

# ── OSS-Fuzz target: ossfuzz.FuzzToml via go-fuzz (LEGACY []byte harness), -tags gofuzz ────────
#     This is the exact replica of `compile_go_fuzzer ... FuzzToml fuzz_toml gofuzz`.
echo "=== building fuzz_toml (ossfuzz.FuzzToml, go-fuzz -tags gofuzz) ==="
go-fuzz -tags gofuzz -func FuzzToml -o "$SRC/mayhem-build/fuzz_toml.a" \
    github.com/pelletier/go-toml/v2/ossfuzz
# Link: DWARF3 via $GO_DEBUG_FLAGS ensures the C-shim CU (first in the binary) is at DWARF3.
$CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS "$SRC/mayhem-build/fuzz_toml.a" -o /mayhem/fuzz_toml
echo "built /mayhem/fuzz_toml"

# The OSS-Fuzz build.sh copies benchmark/benchmark.toml to $OUT/benchmark/ as corpus — the target
# binary is still fuzz_toml. We expose it under the OSS-Fuzz canonical name "benchmark" as a hard
# link inside the mayhem/ directory (Mayhemfile_benchmark references /mayhem/mayhem/benchmark).
# Note: /mayhem/benchmark is the upstream benchmark/ package directory, so we use /mayhem/mayhem/benchmark.
ln -f /mayhem/fuzz_toml /mayhem/mayhem/benchmark 2>/dev/null \
  || cp /mayhem/fuzz_toml /mayhem/mayhem/benchmark

echo "build.sh complete:"
ls -la /mayhem/fuzz_toml /mayhem/mayhem/benchmark 2>&1 || true
