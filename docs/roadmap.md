# OpenCoreX Roadmap

## v0.1 — Simulation-Only Multicycle RV32I Subset Core (Completed: September 11, 2026)

### Architecture
- [x] Define processor architecture
- [x] Select initial 10-instruction RV32I subset
- [x] Complete datapath design
- [x] Document datapath behavior and control signals
- [x] Finalize all datapath MUX encodings
- [x] Audit FSM control outputs state-by-state

### RTL
- [x] Define module interfaces
- [x] Implement primitive RTL modules
- [x] Integrate datapath
- [x] Implement controller FSM
- [x] Integrate complete processor

### Verification
- [x] Develop module-level testbenches
- [x] Verify supported instructions
- [x] Run full processor regression
- [x] Validate example programs

### Future Milestones
- [ ] Expanded RV32I support
- [ ] FPGA implementation
- [ ] Pipelined CPU
- [ ] Processing-in-Memory (PIM) simulator
- [ ] AI hardware accelerator extensions
