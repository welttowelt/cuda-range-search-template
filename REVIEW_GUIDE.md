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

Please return findings with severity, file and line, impact, and a concrete fix. Distinguish verified defects from suggestions and from items that require real-GPU testing.
