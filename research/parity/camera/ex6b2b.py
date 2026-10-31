# Decode the S5K6B2 register writes out of the ISP firmware, from a disassembly in
# d_6b2.txt, into the private sequence file t715-cam-init.py reads. Run from the
# repository root. Its output is Samsung's data: it never enters the repository.
import re,struct
d=open('dumps/vendor_firmware/fimc_is_fw2_4h5.bin','rb').read()
def movw(a):
    h1,h2=struct.unpack_from('<HH',d,a)
    if (h1&0xfbf0)==0xf240 and (h2&0x8000)==0:
        imm4=h1&0xf;i=(h1>>10)&1;imm3=(h2>>12)&7;imm8=h2&0xff;rd=(h2>>8)&0xf
        return rd,(imm4<<12)|(i<<11)|(imm3<<8)|imm8
    return None
regs={}
funcs=[];cur=None
for l in open('d_6b2.txt',errors='replace').read().split('\n'):
    m=re.match(r'\s*(?:[|:\\/`\-,>+ ]*)(0x[0-9a-f]+)\s+(.*)$',l)
    if not m: continue
    a=int(m.group(1),16); ins=m.group(2).strip()
    if a>0x79a00: break
    if ins=='invalid':
        r=movw(a)
        if r: regs['r%d'%r[0]]=r[1]
        continue
    i=re.match(r'(?:movs|movw|mov\.w)\s+(r\d+|sl|sb|fp|ip),\s*(0x[0-9a-f]+|\d+)$',ins)
    if i: regs[i.group(1)]=int(i.group(2),0); continue
    i=re.match(r'mov\s+(r\d+|sl|sb|fp|ip),\s*(r\d+|sl|sb|fp|ip)$',ins)
    if i: regs[i.group(1)]=regs.get(i.group(2)); continue
    if ins.startswith('push.w') or ins.startswith('push '):
        cur={'addr':a,'ops':[]}; funcs.append(cur); continue
    i=re.match(r'bl\s+(0x[0-9a-f]+)',ins)
    if i and cur is not None:
        t=int(i.group(1),16)
        cur['ops'].append((a,t,regs.get('r2'),regs.get('r3')))
    if ins.startswith('blx'): 
        if cur is not None: cur['ops'].append((a,'blx',ins,None))
W={0xd5704:'W8',0xd568e:'W16',0xd582e:'W8pk',0xd5604:'W8hold',0xd58f4:'WN',0xd5966:'RD'}
for f in funcs:
    n=[o for o in f['ops'] if o[1] in W]
    if not n: continue
    print('FUNC',hex(f['addr']),len(n))
    for o in f['ops']:
        if o[1] in W:
            print('   ',hex(o[0]),W[o[1]],hex(o[2]) if isinstance(o[2],int) else o[2],hex(o[3]) if isinstance(o[3],int) else o[3])
