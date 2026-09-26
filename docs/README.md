# Documentation index

The [root README](../README.md) summarizes the implemented system, repository layout, verification flow, and current limits. The [roadmap](roadmap.md) records milestone status; the [devlog](devlog.md) preserves the chronological development record.

## Architecture

- [Multicycle CPU architecture v0.1](architecture/architecture-v0.1.md), [BNE extension](architecture/bne-extension.md), and [scalar MUL extension](architecture/scalar-mul-extension.md)
- [Memory interface v0.1](architecture/memory-interface-v0.1.md) and [Phase 1 shared-memory interface](architecture/pim-memory-interface.md)
- [PIM architecture v0.1](architecture/pim-architecture-v0.1.md) and [module interface contract](architecture/pim-module-interfaces-v0.1.md)
- [Datapath diagram](architecture/diagrams/opencorex-datapath.svg) and [editable source](architecture/diagrams/opencorex-datapath.drawio)

The v0.1 architecture and PIM interface documents retain their dated design decisions. Their status notes identify what has since been implemented.

## Verification and evaluation

- [CPU-driven PIM system regression](verification/pim-system-regression.md)
- [Evaluation methodology](evaluation/evaluation-methodology.md) and [PIM event accounting](evaluation/pim-event-accounting.md)
- [NeuroSim/PiMulator scope record](evaluation/neurosim-pimulator-scope-2026-09-24.md)

## Programs and executable evidence

- [Matrix-vector benchmark](../programs/matvec_1x16_16x32.md) and [CPU-driven PIM offload benchmark](../programs/pim_offload_1x16_16x32.md)
- [Integration smoke](../programs/integration_smoke.md), [corner cases](../programs/integration_corner_cases.md), [scalar MUL](../programs/scalar_mul.md), and [dot product](../programs/dot_product_16.md)
- [Testbenches](../tb/) and [verification script](../scripts/verify.sh)
