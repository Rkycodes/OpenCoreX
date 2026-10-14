"""Generate separate, nested 1x16 by 16xN scaling images; never rewrite history."""
import argparse
import json
from pathlib import Path
import generate_matvec_1x16_16x32 as rv

ROOT=Path(__file__).resolve().parents[1]
HEX=ROOT/"programs/scaling/hex"
SIZES=(32,64,128)
RAM_WORDS=262144
VECTOR=0x100
CONSTANTS=0x200
SIGNATURE=0x220
DONE=0x224
KERNEL=0xa00
KERNEL_END=0xe00
MATRIX=0x1000
OUTPUT=0x10000
LITERALS=(VECTOR,MATRIX,OUTPUT,0,0x40000000)

def word_address(byte_address):
    assert byte_address%4==0
    word=byte_address//4
    assert word*4==byte_address and 0<=word<RAM_WORDS
    return word

def operands(n):
    vector=rv.generate_vector()
    # Keep the historical first 32 columns; break the old period-37 repetition.
    logical=[[
        ((11*i+7*j+3*i*j)%37)-18+(j//37)*(i%5+1)
        for j in range(n)] for i in range(16)]
    expected=[sum(vector[i]*logical[i][j] for i in range(16)) & 0xffffffff
              for j in range(n)]
    serialized=[logical[i][j]&0xffffffff for j in range(n) for i in range(16)]
    assert any(v<0 for row in logical for v in row)
    assert any(v>0 for row in logical for v in row)
    assert len({tuple(logical[i][j] for i in range(16)) for j in range(n)})==n
    assert expected[:32]==rv.calculate_reference(vector,rv.generate_logical_matrix())
    return vector,logical,serialized,expected

def program(mode):
    if mode=="resident":
        code=[rv.lw(5,0,CONSTANTS),rv.lw(6,0,CONSTANTS+4),
              rv.lw(7,0,CONSTANTS+8),rv.lw(8,0,CONSTANTS+12)]
        code += [rv.lw(15+i,5,4*i) for i in range(16)]
        loop_pc=KERNEL+4*len(code)
        loop=[rv.addi(11,0,0)]
        for i in range(16):
            loop += [rv.lw(12,6,4*i),rv.mul(14,15+i,12),rv.add(11,11,14)]
        loop += [rv.sw(11,7),rv.addi(6,6,64),rv.addi(7,7,4),rv.addi(8,8,-1)]
        loop += [rv.bne(8,0,loop_pc-(KERNEL+4*(len(code)+len(loop))))]
        assert len(loop)==54
        code += loop+[rv.lw(31,0,SIGNATURE),rv.sw(31,0,DONE),rv.jal(0,0)]
        assert len(code)==77
    elif mode=="offload":
        code=[rv.lw(1,0,CONSTANTS+16),rv.lw(2,0,CONSTANTS),rv.sw(2,1,0),
              rv.addi(2,0,16),rv.sw(2,1,4),
              rv.lw(2,0,CONSTANTS+4),rv.sw(2,1,8),
              rv.addi(2,0,64),rv.sw(2,1,12),
              rv.lw(2,0,CONSTANTS+8),rv.sw(2,1,16),
              rv.lw(2,0,CONSTANTS+12),rv.sw(2,1,20),
              rv.addi(2,0,1),rv.sw(2,1,24),
              rv.lw(3,1,28),rv.addi(4,0,6),
              rv.encode_r_type(funct7=0,rs2=4,rs1=3,funct3=7,rd=5),
              rv.addi(6,0,2),rv.bne(5,6,16),
              rv.lw(31,0,SIGNATURE),rv.sw(31,0,DONE),
              rv.jal(0,0),rv.jal(0,0)]
        assert len(code)==24
    else:
        raise ValueError(mode)
    assert KERNEL+((len(code)*4+15)//16)*16<=KERNEL_END
    return code

def image_text(mode,n):
    vector,logical,weights,expected=operands(n)
    literals=list(LITERALS)
    literals[3]=n
    constants=literals+[0]*(16-len(literals))
    constants[(SIGNATURE-CONSTANTS)//4]=rv.COMPLETION_SIGNATURE
    code=program(mode)
    padded=code+[0]*((-len(code))%4)
    regions=[(0,[rv.jal(0,KERNEL),0,0,0]),(VECTOR,[v&0xffffffff for v in vector]),
             (CONSTANTS,constants),(KERNEL,padded),(MATRIX,weights),(OUTPUT,[0]*n)]
    assert MATRIX+len(weights)*4<=0x10000
    assert OUTPUT+4*n<=0x11000
    for (start,words),(next_start,_) in zip(regions,regions[1:]):
        assert start+4*len(words)<=next_start
    text=[]
    for byte_start,words in regions:
        text.append(f"@{word_address(byte_start):08x}")
        text.extend(f"{word:08x}" for word in words)
    return "\n".join(text)+"\n","".join(f"{v:08x}\n" for v in expected)

def generate(check=False,sizes=SIZES):
    HEX.mkdir(parents=True,exist_ok=True)
    files={}
    for n in sizes:
        for mode in ("resident","offload"):
            image,expected=image_text(mode,n)
            files[f"{mode}_{n}.hex"]=image
            files[f"expected_{n}.hex"]=expected
    for name,text in files.items():
        p=HEX/name
        if check:
            assert p.read_text()==text,f"image differs: {p}"
        else:
            p.write_text(text)
    # Code is exactly identical across sizes; only literals and operand extents vary.
    for n in sizes:
        vector,matrix,_,_=operands(n)
        large=operands(128)[1]
        assert vector==rv.generate_vector()
        assert all(matrix[i]==large[i][:n] for i in range(16))
    return files

if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check",action="store_true")
    parser.add_argument("--size",type=int,choices=SIZES)
    args=parser.parse_args()
    generate(args.check,(args.size,) if args.size else SIZES)
    print("PASS: scaling images, nested operands, independent references and allocations")
