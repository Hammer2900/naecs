# Package

version       = "0.1.0"
author        = "Tsybulskyi Evhenyi"
description   = "A new awesome nimble package"
license       = "MIT"
srcDir        = "src"


# Dependencies

requires "nim >= 2.2.6"

task docs, "Generate HTML documentation":
  ## Generates the project's HTML documentation and places it in the `docs/` directory.
  exec "nim doc --project --outdir:docs src/naecs.nim"

task clean, "Clean up build artifacts and caches":
  ## Removes all generated files, including nimcache, test binaries, and documentation.
  exec "rm -rf nimcache"
  exec "rm -rf docs"
  exec "rm -f tests/test1 tests/bench" # Remove specific test binaries
  echo "Project cleaned."

task run_tests, "Compile and run all unit tests":
  ## A convenient alias for `nimble test`.
  exec "nimble test"

task run_bench, "Compile and run the benchmark in release mode":
  ## Compiles and runs the benchmark with optimizations enabled for accurate results.
  exec "nim compile -d:release --run tests/bench.nim"