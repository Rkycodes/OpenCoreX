"""Weight-buffered conv1 images; preserve the original A-D generator and receipts."""
import argparse
import hashlib
import json
import time

import generate_conv1 as base
from conv1_reference import convolve

ROOT = base.ROOT
BUILD = ROOT/"obj_dir/verification/conv1_weight_reuse"
IMAGES = BUILD/"images"
FILTER_OUTPUT = 0x32000
CASES = base.CASES


def program():
    """Reuse the exact A-D runtime packer, then buffer each filter's weights."""
    original = base.program("offload")
    marker = [base.rv.addi(1,0,2),base.rv.sw(1,0,base.PHASE)]
    matches = [i for i in range(len(original.code)-1) if original.code[i:i+2] == marker]
    assert len(matches) == 1
    end = matches[0]+2
    a = base.Assembler()
    a.code = original.code[:end]
    a.constants = original.constants[:2]
    assert a.constants == [base.INPUT,base.PATCH]
    a.load(5,base.WEIGHTS); a.load(19,base.PATCH); a.load(7,FILTER_OUTPUT)
    a.emit(base.rv.addi(21,0,base.POSITIONS),base.rv.addi(9,0,base.K),
           base.rv.addi(20,0,base.FILTERS))
    a.load(1,0x40000000)
    a.label("compute_filter")
    a.emit(base.rv.sw(5,1,0),base.rv.sw(9,1,4),base.rv.sw(19,1,8),
           base.rv.addi(2,0,4*base.K),base.rv.sw(2,1,12),base.rv.sw(7,1,16),
           base.rv.sw(21,1,20),base.rv.addi(2,0,1),base.rv.sw(2,1,24),
           base.rv.lw(3,1,28),base.rv.addi(4,0,6),
           base.rv.encode_r_type(funct7=0,rs2=4,rs1=3,funct3=7,rd=6),
           base.rv.addi(4,0,2))
    a.branch(6,4,"failure")
    a.emit(base.rv.addi(5,5,4*base.K),base.rv.addi(7,7,4*base.POSITIONS),
           base.rv.addi(20,20,-1))
    a.branch(20,0,"compute_filter")
    a.phase(3)
    # Gather filter-first raw values while applying bias/ReLU; no separate copy.
    a.load(5,FILTER_OUTPUT); a.load(7,base.OUTPUT)
    a.load(19,base.BIAS); a.load(23,2**31)
    a.emit(base.rv.addi(20,0,base.POSITIONS),base.rv.addi(21,0,base.FILTERS))
    a.label("post_position")
    a.emit(base.rv.addi(10,5,0),base.rv.addi(6,19,0),base.rv.addi(8,21,0))
    a.label("post_filter")
    a.emit(base.rv.lw(11,10),base.rv.lw(12,6),base.rv.add(11,11,12))
    a.label("bias_check")
    a.emit(base.rv.encode_r_type(funct7=0,rs2=23,rs1=11,funct3=7,rd=13))
    a.branch(13,0,"post_store",equal=True)
    a.emit(base.rv.addi(11,0,0))
    a.label("post_store")
    a.emit(base.rv.sw(11,7),base.rv.addi(10,10,4*base.POSITIONS),
           base.rv.addi(7,7,4),base.rv.addi(6,6,4),base.rv.addi(8,8,-1))
    a.branch(8,0,"post_filter")
    a.emit(base.rv.addi(5,5,4),base.rv.addi(20,20,-1))
    a.branch(20,0,"post_position")
    a.emit(base.rv.lw(31,0,base.SIGNATURE),base.rv.sw(31,0,base.DONE))
    a.label("failure"); a.jump("failure")
    a.finish()
    assert a.code[:end] == original.code[:end]
    return a,end


def generate(check=False):
    start = time.perf_counter()
    baseline,_ = base.generate(check)
    recorded = json.loads((ROOT/"docs/evaluation/conv1-results/proof.json").read_text())
    assert baseline["records"] == recorded["images"], "A-D image identity changed"
    IMAGES.mkdir(parents=True,exist_ok=True)
    records = {}
    for case in CASES:
        image,weights,biases = base.workload(case)
        patches,serialized = base.pack(image),base.serialize(weights)
        expected = convolve(image,weights,biases)
        filter_first = []
        for f in range(64):
            for p in range(20):
                total = 0
                for k in range(27):
                    total = (total + base.signed(serialized[f*27+k]) *
                             base.signed(patches[p*27+k])) & base.MASK
                filter_first.append(total)
        canonical = [filter_first[20*f+p] for p in range(20) for f in range(64)]
        biased = [(value+biases[i%64]) & base.MASK for i,value in enumerate(canonical)]
        final = [word if word < 2**31 else 0 for word in biased]
        assert (canonical,biased,final) == expected
        assert filter_first != canonical, "test pattern must detect missing reordering"
        for name,values in zip(("raw","biased","final","patches"),(*expected,patches)):
            path = IMAGES/f"{case}_{name}.hex"
            text = "".join(f"{value:08x}\n" for value in values)
            if check: assert path.read_text() == text
            else: path.write_text(text)
        a,packer_words = program()
        code = a.code+[0]*(-len(a.code)%4)
        regions = [(0,[base.rv.jal(0,base.KERNEL),0,0,0]),
            (base.SIGNATURE,[base.rv.COMPLETION_SIGNATURE,0,0]),
            (base.CONSTANTS,a.constants),(base.KERNEL,code),
            (base.INPUT,[value & base.MASK for plane in image for row in plane for value in row]),
            (base.PATCH,[0xa5a5a5a5]*540),(base.WEIGHTS,serialized),
            (base.BIAS,[value & base.MASK for value in biases]),
            (base.OUTPUT,[0xdeadbeef]*1280),(FILTER_OUTPUT,[0xbaadf00d]*1280)]
        text = base.hex_text(regions)
        path = IMAGES/f"{case}_weights.hex"
        if check: assert path.read_text() == text
        else: path.write_text(text)
        records[case] = dict(image=str(path.relative_to(ROOT)),bias_pc=a.labels["bias_check"],
            code_words=len(code),image_text_bytes=len(text.encode()),
            placed_words=sum(len(v) for _,v in regions),
            sha256=hashlib.sha256(text.encode()).hexdigest(),
            common_packer_words=packer_words,
            common_packer_sha256=hashlib.sha256(b"".join(v.to_bytes(4,"little") for v in code[:packer_words])).hexdigest())
    receipt = dict(cases=list(CASES),outputs_per_case=1280,checked_stage_words=7680,
        baseline_image_identity="all eight A-D images match the original proof receipt",
        records=records)
    text = json.dumps(receipt,indent=2)+"\n"
    if check: assert (IMAGES/"manifest.json").read_text() == text
    else: (IMAGES/"manifest.json").write_text(text)
    print("PASS: weight-buffered mapping, fused output reorder, direct reference and unchanged A-D images",flush=True)
    return receipt,time.perf_counter()-start


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check",action="store_true")
    generate(parser.parse_args().check)
