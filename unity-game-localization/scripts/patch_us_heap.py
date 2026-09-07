# patch_us_heap.py — #US 堆原地替换回写骨架（Assembly-CSharp.dll 硬编码文本汉化）
# 配套流程见 references/dll-patch.md b 节；ldstr 全量扫描见 scripts/scan_ldstr.py

# 1) 定位 #US 文件偏移：PE->CLI(dir14)->元数据根->流表 '#US'（#~ 流 heap_sizes 判定索引宽度）
# 2) 遍历堆条目：entries[offset] = (total_bytes, string)；#US 已去重，同串单一条目
# 3) 每条 en->zh：
#      zh_bytes = zh.encode('utf-16-le'); new_total = plen + len(zh_bytes) + 1
#      if new_total > total: 换短译文，或改走 dnSpy MCP patch_method_il（Cecil 扩堆）
#      prefix = enc_prefix(len(zh_bytes) + 1)   # <0x80: 1 字节; <0x4000: 2 字节(0x80|hi,lo)
#      data[start:start+new_total] = prefix + zh_bytes + b'\x00'   # 标志位=0(非ASCII)
#      其余字节补 0x00 —— 其他 token 偏移全部不变
# 4) 写出工作文件 -> 重扫验证（ldstr 站点数不变、0 解码失败）-> 备份原 dll -> 覆盖部署
# 5) 提醒用户 dnSpy 重新加载程序集；切勿在 dnSpy 旧内存状态下 Save Module
