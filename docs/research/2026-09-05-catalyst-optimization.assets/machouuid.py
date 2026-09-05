import struct, sys, os

LC_UUID=0x1b

def read_thin(data, off):
    raw = data[off:off+4]
    if   raw == b'\xcf\xfa\xed\xfe': m='<'; is64=True
    elif raw == b'\xfe\xed\xfa\xcf': m='>'; is64=True
    elif raw == b'\xce\xfa\xed\xfe': m='<'; is64=False
    elif raw == b'\xfe\xed\xfa\xce': m='>'; is64=False
    else: return None
    hdr_size = 32 if is64 else 28
    cputype, cpusubtype = struct.unpack_from(m+'ii', data, off+4)
    ncmds = struct.unpack_from(m+'I', data, off+16)[0]
    p = off + hdr_size
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from(m+'II', data, p)
        if cmd == LC_UUID:
            u = data[p+8:p+24].hex().upper()
            return (cputype, cpusubtype, f"{u[0:8]}-{u[8:12]}-{u[12:16]}-{u[16:20]}-{u[20:32]}")
        if cmdsize == 0: break
        p += cmdsize
    return (cputype, cpusubtype, None)

def dump(path):
    with open(path,'rb') as f:
        data=f.read()
    head = data[:4]
    results=[]
    # Fat magics: CA FE BA BE (32) / CA FE BA BF (64), big-endian offsets
    if head in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        is64 = head == b'\xca\xfe\xba\xbf'
        nfat = struct.unpack_from('>I', data, 4)[0]
        p=8
        for _ in range(nfat):
            if is64:
                cputype,cpusub,offset,size,align = struct.unpack_from('>iiQQI', data, p); p+=32
            else:
                cputype,cpusub,offset,size,align = struct.unpack_from('>iiIII', data, p); p+=20
            r=read_thin(data, offset)
            if r: results.append(r)
    else:
        r=read_thin(data,0)
        if r: results.append(r)
    print(os.path.basename(path))
    for cputype,cpusub,uuid in results:
        print(f"  cputype={cputype} cpusub={cpusub} UUID={uuid}")
    return [r[2] for r in results if r[2]]

if __name__=='__main__':
    all_uuids=[]
    for p in sys.argv[1:]:
        all_uuids += dump(p)
    print("UUIDS:"+",".join(all_uuids))
