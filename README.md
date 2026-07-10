# CUDA Range Search Template

A small, offline CUDA example for reviewing and testing deterministic integer-range search.

The repository demonstrates four reusable engineering ideas:

- split a bounded integer range across one or more GPUs;
- process each device range in deterministic chunks;
- propagate CUDA and worker failures instead of reporting false completion;
- collect a bounded set of matches from a harmless toy predicate.

The included predicate applies SplitMix64 to each integer and matches values whose low bits are zero. It exists only to make the scheduler and error handling testable. Replace it only with workloads you own or are authorized to run.

This project contains no network client, credential handling, wallet logic, key recovery, external target integration, or automatic publishing/submission behavior.

## Requirements

- Linux with an NVIDIA GPU
- CUDA toolkit with `nvcc`
- Bash 3.2 or newer

The orchestration tests do not require a GPU.

## Build

```bash
make build
```

The build script detects the local compute capability. If the installed CUDA toolkit is older than the GPU, it tries a forward-compatible `compute_80` PTX build and fails explicitly if neither build works.

## Run one device

```bash
./build/range-search 0 1000000 12345 20
```

Arguments are:

```text
range-search START COUNT [SEED] [ZERO_BITS] [MATCH_CAPACITY]
```

Matches are printed as `MATCH value=N`. A coverage summary goes to standard error. The program exits nonzero on malformed input, CUDA failure, or match-buffer overflow.

## Run multiple GPUs

```bash
SEARCH_BIN=./build/range-search \
  ./scripts/search-driver.sh 0 10000000 500000 auto 12345 20
```

Arguments are:

```text
search-driver.sh START COUNT [CHUNK] [GPU_COUNT|auto] [SEED] [ZERO_BITS]
```

The driver emits results only if every assigned chunk completes successfully. Per-device diagnostics are retained until the run finishes and are printed if any worker fails.

For portable Bash arithmetic, the driver accepts ranges within `0..2^63-1`. The CUDA executable uses unsigned 64-bit values.

## Test without CUDA

```bash
make test
```

The tests use a fake search executable to verify exact range coverage, deterministic result merging, invalid-input rejection, and worker-failure propagation.

## External review

See [REVIEW_GUIDE.md](REVIEW_GUIDE.md) for a compact checklist suitable for another engineer or LLM reviewer.

## Safety boundary

This is an educational systems template. It performs a local exhaustive search over a caller-supplied integer interval using a toy predicate. Users are responsible for ensuring that any replacement predicate and dataset are lawful and authorized.

## License

MIT
