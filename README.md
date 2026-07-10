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

The orchestration and CPU-reference tests do not require a GPU.

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

To retain a verifiable run and resume completed chunks:

```bash
SEARCH_BIN=./build/range-search \
SEARCH_RUN_DIR=./runs/example \
  ./scripts/search-driver.sh 0 10000000 500000 auto 12345 20

SEARCH_BIN=./build/range-search \
SEARCH_RUN_DIR=./runs/example \
SEARCH_RESUME=1 \
  ./scripts/search-driver.sh 0 10000000 500000 auto 12345 20
```

Each successful chunk records its exact interval, GPU index, binary hash, output hash, match count, seed, and predicate setting. `scripts/verify-manifest.sh` rejects missing, overlapping, reordered, corrupted, or identity-mismatched chunks before the driver emits merged results.

For portable Bash arithmetic, the driver requires `START` and the exclusive end `START + COUNT` to be within `0..2^63-1`. The CUDA executable uses unsigned 64-bit values.

## Test without CUDA

```bash
make test
```

The tests use a fake search executable to verify exact range coverage, deterministic result merging, invalid-input rejection, and worker-failure propagation. A deterministic 24-case parameter matrix compares partitioned execution with the CPU reference, and an adversarial suite corrupts manifests, outputs, binary identity, and resume state.

They also compile a CPU reference executable from the same predicate header and compare a direct CPU search with a differently chunked, three-worker run. This catches scheduler gaps and predicate drift without requiring CUDA.

## External review

See [REVIEW_GUIDE.md](REVIEW_GUIDE.md) for the review questions and [EXTERNAL_REVIEW_TEMPLATE.md](EXTERNAL_REVIEW_TEMPLATE.md) for a structured response format suitable for another engineer or LLM reviewer.

## Safety boundary

This is an educational systems template. It performs a local exhaustive search over a caller-supplied integer interval using a toy predicate. Users are responsible for ensuring that any replacement predicate and dataset are lawful and authorized.

## License

MIT
