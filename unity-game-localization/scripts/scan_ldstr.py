# scan_ldstr.py — 程序集 ldstr 全量扫描（dnfile），一次性输出 "类\t方法\tIL偏移\t字符串" TSV
# 覆盖全部方法体（无需逐个 dnSpy MCP 搜索）；配套流程见 references/dll-patch.md

import dnfile, struct
pe = dnfile.dnPE(r'<Managed>/Assembly-CSharp.dll')
mdt = pe.net.mdtables
# 方法 rid -> 类型全名（TypeDef.MethodList 区间推得）
typedefs = list(mdt.TypeDef)
m2t = {}
for ti, t in enumerate(typedefs):
    ml = t.MethodList
    if not ml: continue
    start = ml[0].row_index
    end = (typedefs[ti+1].MethodList[0].row_index if ti+1 < len(typedefs)
           else len(mdt.MethodDef.rows)+1)
    ns = str(t.TypeNamespace or ''); name = str(t.TypeName)
    for m in range(start, end): m2t[m] = (ns+'.'+name) if ns else name
# 1 字节 opcode 总长表（默认 1），0xFE 前缀第二字节 -> 操作数附加字节数
L1 = [1]*256
for op in range(0x1F,0x20): L1[op]=2
L1[0x20]=5; L1[0x21]=9; L1[0x22]=5; L1[0x23]=9; L1[0x27]=5; L1[0x28]=5; L1[0x29]=5
for op in range(0x2B,0x38): L1[op]=2
for op in range(0x38,0x45): L1[op]=5          # 0x45 switch 特判 5+4n
for op in (0x4F,): L1[op]=5
for op in range(0x6F,0x76): L1[op]=5
L1[0x79]=5
for op in range(0x7B,0x82): L1[op]=5
L1[0x8C]=5; L1[0x8D]=5; L1[0x8F]=5; L1[0xA3]=5; L1[0xA4]=5; L1[0xA5]=5
L1[0xC2]=5; L1[0xC6]=5; L1[0xD0]=5; L1[0xDD]=5; L1[0xDE]=2
FE = {0x00:0,0x01:0,0x02:0,0x03:0,0x04:0,0x05:0,0x06:4,0x07:4,0x09:2,0x0A:2,
      0x0B:2,0x0C:2,0x0D:2,0x0E:2,0x0F:0,0x11:0,0x12:1,0x13:0,0x14:0,
      0x15:4,0x16:4,0x17:0,0x18:4,0x19:4,0x1A:0,0x1B:4}
results = []
for mi, m in enumerate(mdt.MethodDef.rows, start=1):
    if not m.Rva: continue
    off = pe.get_offset_from_rva(m.Rva)          # 不要用 get_data_at_rva
    buf = pe.__data__[off:off+8192]
    b = buf[0]
    if b & 3 == 2: code, size = 1, b >> 2        # tiny header
    else:
        code = (struct.unpack_from('<H', buf, 0)[0] >> 12) * 4
        size = struct.unpack_from('<I', buf, 4)[0]   # fat header
    i, end = code, code + size
    while i < end:
        op = buf[i]
        if op == 0xFE:
            f2 = buf[i+1]
            if f2 not in FE: raise KeyError(hex(f2))  # 未知即 raise，防错位
            i += 2 + FE[f2]; continue
        if op == 0x45:
            n = struct.unpack_from('<I', buf, i+1)[0]; i += 5 + 4*n; continue
        if op == 0x72:                            # ldstr
            tok = struct.unpack_from('<I', buf, i+1)[0]
            s = pe.net.user_strings.get(tok & 0xFFFFFF).value  # 只传低 24 位！
            if s and s.strip(): results.append((m2t.get(mi,'?'), str(m.Name), i-code, s))
            i += 5; continue
        i += L1[op]
# results 逐行写 TSV：type \t method \t il \t 字符串(\t\n 转义)
