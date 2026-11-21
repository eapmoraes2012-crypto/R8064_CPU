#!/usr/bin/env python3
# Random differential test: generates Z80 programs, runs them on the model and on the RTL (iverilog), compares registers, flags and memory.
import random,subprocess,sys,os
from z80model import Z
HERE=os.path.dirname(os.path.abspath(__file__)); SIM=os.path.dirname(HERE); RTL=os.path.join(os.path.dirname(SIM),'rtl')
VVP=os.path.join(HERE,'z80.vvp')
def build():
    f=['r8064_core_min.v','r8064_decode.v','r8064_decode_rom.v','regfile64.v','regmap_b.v','regmerge.v','alu_prep.v','alu_core_s.v','../../03_muldiv/rtl/mul_unit.v','../../03_muldiv/rtl/div_unit.v','../../08_fpu/rtl/fpu_unit.v','../../08_fpu/rtl/fpu_seq.v']
    r=subprocess.run(['iverilog','-g2012','-o',VVP,os.path.join(HERE,'tb_z80.v')]+[os.path.join(RTL,x) for x in f],capture_output=True,text=True)
    if r.returncode: print(r.stderr); sys.exit(1)
for m in ('uop','mainctrl','rom_ed_a','rom_ed_b','amb_idx','ctrl','ctrl_b'):
    d=os.path.join(HERE,m+'.mem')
    if os.path.lexists(d) and not os.path.exists(d): os.remove(d)      # dangling link (e.g. made on another machine)
    if not os.path.exists(d): os.symlink(os.path.join(SIM,m+'.mem'),d)
RG='bcdehl'
def gen(seed,nunits=40,mix=None):
    R=random.Random(seed)
    mem=bytearray(4096)
    # subroutines: 0x300: INC C ; RET   | 0x310: LD A,B ; RET NZ ; INC E ; RET | 0x320: RET Z ; DEC D ; RET
    mem[0x300:0x303]=bytes([0x0C,0xC9,0]); mem[0x310:0x316]=bytes([0x78,0xC0,0x1C,0xC9,0,0]); mem[0x320:0x324]=bytes([0xC8,0x15,0xC9,0])
    mem[0x38]=0xC9; mem[0:3]=bytes([0xC3,0x40,0x00])
    for i in range(0x400,0xE00): mem[i]=R.randrange(256)
    base=bytearray(mem); z=Z(mem)
    for k in RG+'a': z.r[k]=R.randrange(256)
    z.r['f']=R.randrange(256)
    def ptr(): return R.randrange(0x400,0xDF0)
    z.r['h'],z.r['l']=ptr()>>8,ptr()&255; hl=ptr(); z.r['h'],z.r['l']=hl>>8,hl&255
    bc=ptr(); z.r['b'],z.r['c']=bc>>8,bc&255; de=ptr(); z.r['d'],z.r['e']=de>>8,de&255
    z.x['ix']=R.randrange(0x400,0xDF0) if R.random()<0.9 else R.randrange(65536); z.x['iy']=R.randrange(0x400,0xDF0) if R.random()<0.9 else R.randrange(65536)
    init=dict(r=dict(z.r),sp=z.sp,x=dict(z.x))
    z.pc=0x40; cur=[0x40]            # code from 0x40 (0..2: JP 0040h; 38h: RET for RST 38h)
    def emit(bs):
        a=cur[0]; z.m[a:a+len(bs)]=bytes(bs); cur[0]+=len(bs)
    def run_to(end):
        n=0
        while z.pc!=end:
            z.step(); n+=1
            if n>3000: raise RuntimeError('loop')
    def safe_ptr(v): return 0x400<=v<0xE00
    def regonly_instr():
        c=R.choice(['mov','alu','incdec','alui','ldn','cpl','ex'])
        if c=='mov': d=R.choice([0,1,2,3,4,5,7]); r=R.choice([0,1,2,3,4,5,7]); return [0x40|d<<3|r]
        if c=='alu': return [0x80|R.randrange(8)<<3|R.choice([0,1,2,3,4,5,7])]
        if c=='incdec': d=R.choice([0,1,2,3,4,5,7]); return [d<<3|R.choice([4,5])]
        if c=='alui': return [0xC6|R.randrange(8)<<3,R.randrange(256)]
        if c=='ldn': return [0x06|R.choice([0,1,2,3,4,5,7])<<3,R.randrange(256)]
        if c=='cpl': return [0x2F]
        return [0xEB] if False else [0x00]
    start=z.pc
    for u in range(nunits):
        kind=R.choice(['mov','mov','alu','alu','alu','incdec','alui','ldn','mem','memalu','rr','ldrr','jr','jp','call','djnz','ex','cpl','pushpop','ldnn','sp','exxblk','rota','daa','scfccf','addhl','afpp','exsp','cb','cb','rst','ixa','ixa','ixm','ixm','ixcb','edx','edx'])
        if kind=='mov': ins=[0x40|R.choice([0,1,2,3,4,5,7])<<3|R.choice([0,1,2,3,4,5,7])]
        elif kind=='alu': ins=[0x80|R.randrange(8)<<3|R.choice([0,1,2,3,4,5,7])]
        elif kind=='incdec': ins=[R.choice([0,1,2,3,4,5,7])<<3|R.choice([4,5])]
        elif kind=='alui': ins=[0xC6|R.randrange(8)<<3,R.randrange(256)]
        elif kind=='ldn': ins=[0x06|R.choice([0,1,2,3,4,5,7])<<3,R.randrange(256)]
        elif kind in ('ixa','ixm','ixcb'):
            pre=R.choice([0xDD,0xFD]); nm='ix' if pre==0xDD else 'iy'; xv=z.x[nm]
            d=R.randrange(-128,128); ad=(xv+d)&0xFFFF
            if kind=='ixa':
                c=R.choice(['ld','add','incdec','ldnn','pp','exsp','spx','hlops'])
                if c=='ld': v=R.randrange(0x400,0xDF0) if R.random()<0.7 else R.randrange(65536); ins=[pre,0x21,v&255,v>>8]
                elif c=='add': ins=[pre,R.choice([0x09,0x19,0x29,0x39])]
                elif c=='incdec': ins=[pre,R.choice([0x23,0x2B])]
                elif c=='ldnn': a=R.randrange(0x400,0xDF0); ins=[pre,R.choice([0x22,0x2A]),a&255,a>>8]
                elif c=='pp': ins=[pre,R.choice([0xE5,0xE1])]
                elif c=='exsp': ins=[pre,0xE3]
                elif c=='spx': ins=[pre,0xF9] if 0x500<=xv<0xD00 else [0x00]
                else:     # IXH/IXL: LD r,r' / ALU / INC / DEC / LD r,n
                    h2=R.choice([4,5]); o=R.choice(['mov','alu','incdec','ldn'])
                    if o=='mov':
                        o2=R.choice([0,1,2,3,7]); ins=[pre,0x40|(h2<<3|o2 if R.random()<.5 else o2<<3|h2)]
                        if ins[1]==0x40|(h2<<3|h2): ins=[pre,0x40|(h2<<3|h2)]
                    elif o=='alu': ins=[pre,0x80|R.randrange(8)<<3|h2]
                    elif o=='incdec': ins=[pre,h2<<3|R.choice([4,5])]
                    else: ins=[pre,0x06|h2<<3,R.randrange(256)]
            elif kind=='ixm':
                if not safe_ptr(ad): ins=[0x00]
                else:
                    o=R.choice(['ld','st','inc','dec','ldn','alu'])
                    if o=='ld': ins=[pre,0x46|R.choice([0,1,2,3,4,5,7])<<3,d&255]
                    elif o=='st': ins=[pre,0x70|R.choice([0,1,2,3,4,5,7]),d&255]
                    elif o=='inc': ins=[pre,0x34,d&255]
                    elif o=='dec': ins=[pre,0x35,d&255]
                    elif o=='ldn': ins=[pre,0x36,d&255,R.randrange(256)]
                    else: ins=[pre,0x86|R.randrange(8)<<3,d&255]
            else:
                op4=R.randrange(256)&0xF8|6
                ins=[pre,0xCB,d&255,op4] if safe_ptr(ad) and (op4>>6)!=1 else [0x00]
        elif kind=='edx':
            c=R.choice(['adc','neg','ldnn','ldrr','rld'])
            if c=='adc': ins=[0xED,R.choice([0x42,0x52,0x62,0x72,0x4A,0x5A,0x6A,0x7A])]
            elif c=='neg': ins=[0xED,0x44]
            elif c=='ldnn': a=R.randrange(0x400,0xDF0); ins=[0xED,R.choice([0x43,0x53,0x63,0x73,0x4B,0x5B,0x6B]),a&255,a>>8]
            elif c=='ldrr': a=R.randrange(0x400,0xDF0); ins=[0xED,R.choice([0x43,0x53,0x63,0x73]),a&255,a>>8]
            else: ins=[0xED,R.choice([0x6F,0x67])] if safe_ptr(z.pr('hl')) else [0x00]
        elif kind=='rota': ins=[R.choice([0x07,0x0F,0x17,0x1F])]
        elif kind=='daa': ins=[0x27]
        elif kind=='scfccf': ins=[R.choice([0x37,0x3F])]
        elif kind=='addhl': ins=[R.choice([0x09,0x19,0x29,0x39])]
        elif kind=='afpp': ins=R.choice([[0xF5,R.choice([0xC1,0xD1,0xE1])],[R.choice([0xC5,0xD5,0xE5]),0xF1],[0xF5,0xF1]])
        elif kind=='exsp': ins=[0xE3]
        elif kind=='rst': ins=[0xFF]
        elif kind=='cb':
            r=R.choice([0,1,2,3,4,5,6,7]); o=R.randrange(256)&0xF8|r
            if r==6 and (not safe_ptr(z.pr('hl')) or (o>>6)==1): o=o&0xF8|R.choice([0,1,2,3,4,5,7])
            ins=[0xCB,o]
        elif kind=='cpl': ins=[0x2F]
        elif kind=='ex': ins=[0xEB]
        elif kind=='exxblk':
            blk=[]
            for _ in range(R.randrange(2,7)): blk+=regonly_instr()
            ins=[0xD9]+blk+[0xD9]
        elif kind=='rr': ins=[R.choice([0x03,0x13,0x23,0x0B,0x1B,0x2B])]
        elif kind=='ldrr':
            op=R.choice([0x01,0x11,0x21]); v=R.randrange(0x400,0xDF0) if R.random()<0.7 else R.randrange(65536); ins=[op,v&255,v>>8]
        elif kind=='sp': ins=R.choice([[0xF9] if (0x500<=z.pr('hl')<0xD00) else [0x00],[0x31,0x00,0x0F]])
        elif kind=='pushpop': ins=[R.choice([0xC5,0xD5,0xE5]),R.choice([0xC1,0xD1,0xE1])]
        elif kind=='ldnn':
            a=R.randrange(0x400,0xDF0); ins=R.choice([[0x3A,a&255,a>>8],[0x32,a&255,a>>8],[0x2A,a&255,a>>8],[0x22,a&255,a>>8]])
        elif kind=='mem':
            ch=R.choice(['ldhl','sthl','ldbc','ldde','stbc','stde','inchl','dechl','ldhln'])
            hlv,bcv,dev=z.pr('hl'),z.pr('bc'),z.pr('de')
            if ch=='ldhl' and safe_ptr(hlv): ins=[0x46|R.choice([0,1,2,3,4,5,7])<<3]
            elif ch=='sthl' and safe_ptr(hlv): ins=[0x70|R.choice([0,1,2,3,4,5,7])]
            elif ch=='ldbc' and safe_ptr(bcv): ins=[0x0A]
            elif ch=='ldde' and safe_ptr(dev): ins=[0x1A]
            elif ch=='stbc' and safe_ptr(bcv): ins=[0x02]
            elif ch=='stde' and safe_ptr(dev): ins=[0x12]
            elif ch=='inchl' and safe_ptr(hlv): ins=[0x34]
            elif ch=='dechl' and safe_ptr(hlv): ins=[0x35]
            elif ch=='ldhln' and safe_ptr(hlv): ins=[0x36,R.randrange(256)]
            else: ins=[0x00]
        elif kind=='memalu':
            ins=[0x86|R.randrange(8)<<3] if safe_ptr(z.pr('hl')) else [0x00]
        elif kind=='jr':
            cc=R.choice([0x18,0x20,0x28,0x30,0x38]); blk=[];
            for _ in range(R.randrange(1,4)): blk+=regonly_instr()
            ins=[cc,len(blk)]+blk
        elif kind=='jp':
            cc=R.randrange(8); blk=[]
            for _ in range(R.randrange(1,4)): blk+=regonly_instr()
            tgt=cur[0]+(3 if R.random()<2 else 0)+len(blk)
            ins=[0xC2|cc<<3,tgt&255,tgt>>8]+blk if R.random()<0.85 else [0xC3,(cur[0]+3+len(blk))&255,(cur[0]+3+len(blk))>>8]+blk
        elif kind=='call':
            sub=R.choice([0x300,0x310,0x320]); cc=R.choice([None]+list(range(8)))
            ins=[0xCD,sub&255,sub>>8] if cc is None else [0xC4|cc<<3,sub&255,sub>>8]
        elif kind=='djnz':
            n=R.randrange(1,5); blk=[]
            for _ in range(R.randrange(1,3)):
                i=regonly_instr()
                if i[0] in (0x04,0x05,0x06): continue    # do not touch B (counter)
                if (i[0]&0xC0)==0x40 and (i[0]>>3&7)==0: continue
                if (i[0]&0xC7) in (4,5,6) and (i[0]>>3&7)==0: continue
                blk+=i
            ins=[0x06,n]+blk+[0x10,(-(len(blk)+2))&255]
        a0=cur[0]; emit(ins)
        try: run_to(cur[0])
        except (RuntimeError,ValueError): return None
    emit([0x18,0xFE]); end=cur[0]-2
    img=bytearray(base); img[0x40:cur[0]]=z.m[0x40:cur[0]]
    return img,init,end

def expected(img,init,end):
    z=Z(img)
    for k,v in init['r'].items(): z.r[k]=v
    z.x=dict(init['x'])
    z.sp=init['sp']; z.pc=0x40; n=0
    while z.pc!=end:
        z.step(); n+=1
        if n>6000: return None
    return z,n
def run_rtl(img,init,ncyc):
    os.chdir(HERE)
    open('z80mem.hex','w').write(''.join('%02x\n'%b for b in img))
    r=init['r']; regs=[0]*16
    regs[0]=r['a']; regs[1]=r['b']<<8|r['c']; regs[2]=r['d']<<8|r['e']; regs[3]=r['h']<<8|r['l']; regs[11]=init['sp']; regs[9]=init['x']['ix']; regs[10]=init['x']['iy']
    open('z80regs.hex','w').write(''.join('%016x\n'%x for x in regs)); open('z80fl.hex','w').write('%02x\n'%r['f'])
    p=subprocess.run(['vvp',VVP,'+cyc=%d'%ncyc],capture_output=True,text=True)
    L=open('z80out.txt').read().split('\n')
    R={}; 
    for l in L[:18]:
        k,v=l.split(); R[k]=int(v,16)
    mem=bytes(int(x,16) for x in L[18:18+4096])
    return R,mem
def compare(seed,nunits=90):
    g=gen(seed,nunits)
    if g is None: return 'skip'
    img,init,end=g; e=expected(img,init,end)
    if e is None: return 'skip'
    z,n=e
    R,mem=run_rtl(img,init,60*n+1500)
    errs=[]
    exp=dict(a=z.r['a'],bc=z.pr('bc'),de=z.pr('de'),hl=z.pr('hl'),sp=z.sp)
    got=dict(a=R['R0']&0xFFFF_FFFF_FFFF_FFFF,bc=R['R1'],de=R['R2'],hl=R['R3'],sp=R['R11'])
    for k in exp:
        if exp[k]!=got[k]: errs.append('%s esp %x obt %x'%(k,exp[k],got[k]))
    sh=z.sh
    for nm,ix,(hi,lo) in (('bc2',6,'bc'),('de2',7,'de'),('hl2',8,'hl')):
        ev=sh[hi]<<8|sh[lo]
        if R['R%d'%ix]!=ev: errs.append('%s esp %x obt %x'%(nm,ev,R['R%d'%ix]))
    for nm,ix in (('ix',9),('iy',10)):
        if R['R%d'%ix]!=z.x[nm]: errs.append('%s esp %x obt %x'%(nm,z.x[nm],R['R%d'%ix]))
    if R['F']!=z.r['f']: errs.append('F esp %02x obt %02x'%(z.r['f'],R['F']))
    if mem[0x400:0xF00]!=bytes(z.m[0x400:0xF00]):
        d=[i for i in range(0x400,0xF00) if mem[i]!=z.m[i]]; errs.append('mem difere em %s'%[hex(x) for x in d[:6]])
    return errs,img,end,n
if __name__=='__main__':
    build()
    a=int(sys.argv[1]) if len(sys.argv)>1 else 1; b=int(sys.argv[2]) if len(sys.argv)>2 else 20
    nb=0; nsk=0
    for seed in range(a,b+1):
        r=compare(seed)
        if r=='skip': nsk+=1; continue
        errs,img,end,n=r
        if errs: nb+=1; print('seed',seed,'instr',n,errs[:4])
    print('seed %d..%d: %d with error, %d skipped'%(a,b,nb,nsk))
