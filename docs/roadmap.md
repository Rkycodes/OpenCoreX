# OpenCoreX Roadmap

## v0.1 — Simulation-Only Multicycle RV32I Core (Target: September 1, 2026)

### Architecture
- [x] Define processor architecture
- [x] Select initial 10-instruction RV32I subset
- [x] Complete datapath design
- [x] Document datapath behavior and control signals
- [x] Finalize all datapath MUX encodings
- [x] Audit FSM control outputs state-by-state

### RTL
- [x] Define module interfaces
- [ ] Implement primitive RTL modules
- [ ] Integrate datapath
- [ ] Implement controller FSM
- [ ] Integrate complete processor

### Verification
- [ ] Develop module-level testbenches
- [ ] Verify supported instructions
- [ ] Run full processor regression
- [ ] Validate example programs

### Future Milestones
- [ ] Expanded RV32I support
- [ ] FPGA implementation
- [ ] Pipelined CPU
- [ ] Processing-in-Memory (PIM) simulator
- [ ] AI hardware accelerator extensions
