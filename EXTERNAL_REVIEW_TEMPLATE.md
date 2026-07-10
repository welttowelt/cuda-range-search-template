# External Review Template

Use this format to review the repository as a generic, offline CUDA range-search
example. Do not infer behavior from names alone: cite code, test output, or an
exact reproduction for every defect claim.

## Review environment

```text
reviewer:
review date:
commit:
operating system and architecture:
bash version:
C++ compiler:
CUDA toolkit and nvcc version: not available / version
GPU model and driver: not available / model and version
commands run:
```

## Verification status

Mark each item with one of `pass`, `fail`, or `not run`.

```text
make test:
Bash 3.2 test run:
CPU reference built:
CPU direct vs partitioned comparison:
manifest adversarial tests:
CUDA build:
single-GPU run:
multi-GPU run:
compute-sanitizer or equivalent:
```

Use these evidence labels consistently:

- `confirmed-defect`: reproduced or proved directly from reachable code.
- `cpu-tested`: supported by a CPU/fake-worker test, but not a real CUDA run.
- `cuda-verified`: reproduced on the stated NVIDIA hardware and toolchain.
- `cuda-unverified`: plausible CUDA-specific concern that was not reproduced.
- `suggestion`: maintainability, clarity, or hardening idea without a current defect.

## Findings

Repeat this block for each finding. If there are no findings, write `None` and
still complete the residual-risk section.

```text
Finding ID: F-001
Title:
Evidence label: confirmed-defect / cpu-tested / cuda-verified / cuda-unverified / suggestion
Severity: critical / high / medium / low / informational
Confidence: high / medium / low
Location: path:line

Observed behavior:
Expected behavior:
Impact:
Evidence or exact reproduction:
Root cause:
Proposed fix:
Regression test:
GPU required to close this finding: yes / no
```

Do not report a CUDA-unverified hypothesis as a confirmed defect. Conversely,
do not treat passing CPU orchestration tests as proof that CUDA allocation,
kernel launch, synchronization, or device-copy paths are correct.

## Coverage and invariants checked

Briefly state what evidence supports each conclusion:

```text
Range [START, START + COUNT) covered exactly once:
Worker failure cannot become an empty success:
Match-buffer overflow fails explicitly:
Manifest gaps, overlaps, duplicates, and corruption fail closed:
Resume binds chunks to executable and output hashes:
Direct and partitioned results are deterministic:
CPU and CUDA compile the same predicate definition:
Unsigned-range and overflow boundaries are consistent:
```

## Residual risk and next test

```text
Most important unverified risk:
Smallest test that would resolve it:
Required hardware/toolchain:
Expected pass condition:
Expected failure evidence:
```

## Final assessment

Choose exactly one:

```text
ready for generic public example use
ready after listed confirmed defects are fixed
CPU side reviewed; CUDA validation still required
not ready, for the reasons above
```

End with a short rationale and list the finding IDs that block readiness.
