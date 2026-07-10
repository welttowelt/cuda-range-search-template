# Review Guide

Please review this repository as a generic CUDA systems example. The most useful questions are:

1. Does `scripts/search-driver.sh` cover every integer in `[START, START + COUNT)` exactly once?
2. Can a CUDA process, device, or chunk failure be mistaken for a successful empty result?
3. Are integer overflow and malformed CLI inputs rejected consistently?
4. Does `src/range_search.cu` check every CUDA allocation, launch, synchronization, and copy operation?
5. Can the bounded match buffer silently lose results?
6. Are results deterministic across chunk sizes and GPU counts?
7. Are the Bash scripts portable to Bash 3.2 and common Linux environments?
8. Is any documentation or code ambiguous about the toy, offline, authorized-use scope?
9. Does resume mode verify the binary and output hashes before skipping a chunk?
10. Can a malformed, duplicated, missing, or out-of-order chunk metadata file pass `verify-manifest.sh`?
11. Do the CPU and CUDA implementations actually compile the same predicate definition?

Please return findings using [EXTERNAL_REVIEW_TEMPLATE.md](EXTERNAL_REVIEW_TEMPLATE.md). Include severity, file and line, evidence, impact, a concrete fix, and a regression test. Distinguish confirmed defects from suggestions, CPU-tested behavior, and items that require real-GPU testing.
