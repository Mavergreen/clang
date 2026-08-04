# mavericks-clang

An unofficial community build of **Clang/LLVM for Mavericks** — a clang toolchain that
runs on modern Apple-Silicon macOS and targets **Mac OS X 10.9 (Mavericks)** out of the box.
Not affiliated with the LLVM project.

`clang++ foo.cpp -o foo` produces a working `x86_64` 10.9 binary with the legacy-support
polyfill linked — no extra flags.

## Layout
- `build/` — the CI cross-build (runs on a modern arm64 runner).
- `native-bootstrap/` — Wowfunhappy's original on-10.9 bootstrap scripts, kept for a future
  local-Mavericks build phase; not used by CI.
