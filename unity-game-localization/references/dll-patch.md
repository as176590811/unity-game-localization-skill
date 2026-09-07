# 代码内硬编码文本（Assembly-CSharp.dll 等，dnSpy MCP + dnfile）

assets 提取回写完成后**必查**的一类遗漏：硬编码在程序集 #US 堆里的 UI 文本（`Funds {0}/{1}G`、`Critical hit!`、`Rarity: Legendary`、`Enter battle!`、技能名等）。这类文本不在任何 .assets 里，assets 回写改不了，必须改 dll 或运行时接管（XUnity.AutoTranslator）。触发特征：游戏明显还有未汉化的界面文字但 assets 里找不到对应原文。

## a. 定位与提取

| 步骤 | 工具 | 要点 |
| --- | --- | --- |
| 1. 加载程序集 | dnSpy MCP `open_files`（传 Managed 目录，一次全加载）→ `list_assemblies` 确认 | firstpass 只含引擎内部消息，主文本在 Assembly-CSharp |
| 2. 反查所有者 | `search_string_literals assembly_name query=<片段>`（大小写不敏感子串）返回 type/method/method_token | 用几条代表性文本反查即可锁定所有者类，不必逐条搜 |
| 3. 逐类全量清单 | `list_string_constants assembly_name type_full_name=<类>`（10 条/页，cursor 翻页）；类大时改 `decompile_type`/`decompile_method` 看用法 | 拿到"类.方法 × 字符串"对照，用于甄别显示文本 vs Debug.Log |
| 4. 拼接句确认 | `decompile_method` 看字符串拼接上下文（如 `a + " is " + b + " near capture!"`） | 拼接碎片要**整体设计译文**：碎片分别替换后必须连读通顺，且各自受字节预算约束（见 b 节第 3 步） |
| 5. 全量扫描（可选，最彻底） | Python `pip install dnfile`，跑 `scripts/scan_ldstr.py`：解析 TypeDef/MethodDef 表 + 逐方法体 IL 扫 `ldstr`(0x72) → 一次性得到全部 ldstr→(type,method) 映射 TSV | 骨架与完整 opcode 长度表见 scripts/scan_ldstr.py；dnfile API 坑见文末 |
| 6. 甄别 | 三类：①显示文本（`.text =`/`string.Format` 赋值）→ 译；②`Debug.Log`/异常消息 → 不译；③**与逻辑共用的键**（枚举 ToString 比较、资源小写键 'wood'、动画/场景名）→ **禁译** | 判定 ③ 的方法：同一字符串出现在 switch/比较方法里（如 `'All'` 同时用于 enchant 稀有度键与分类显示）则禁译，宁可保留英文 |

## b. 回写：#US 字符串堆原地替换（安全、免改 IL）

ldstr token 指向 #US 堆的固定偏移，因此把每个堆条目**原地**重写为"压缩长度前缀 + UTF-16LE 数据 + 标志字节 0x00"、剩余字节补 0x00，所有其他 token 偏移不变，运行时无需任何校验。步骤骨架：`scripts/patch_us_heap.py`。

1. 解析 PE→CLI→元数据流定位 `#US` 文件偏移（`#~` 流 heap_sizes 判定各索引宽度）。
2. 遍历堆条目建立 offset→(总字节数, 字符串) 映射（#US 去重，同串单一条目）。
3. 对每条 en→zh：新条目总字节数（前缀 + 2×字符数 + 1）**必须 ≤ 原条目总字节数**，否则该条改用 dnSpy MCP `patch_method_il`（Cecil 可扩堆）或缩短译文。**短拼接碎片预算极紧**：如 `'!'` 原条目仅 4 字节，只能放 1 个字符——用全角 `'！'`，把其余语义挪进相邻碎片（如 `' captured by '`→`' 被捕获！凶手是'`）。
4. 原地写回 + 补零 → 输出到工作文件 → 用扫描脚本**重新扫描验证**（ldstr 站点数必须与原文件一致、译文在位、0 解码失败）→ 检查 `CLR_STRONGNAMESIGNED`（Unity 程序集通常为 False）→ 备份原 dll（如 `<名>.dll.zh_patch_bak_<日期>`）→ 覆盖部署。
5. **警告 dnSpy 用户**：外部改文件后 dnSpy 内存里还是旧版本，必须重新加载程序集，**切勿在旧状态下 Save Module**（会把补丁覆盖回英文）。或全部回写走 dnSpy MCP（`patch_method_il` + `save_assembly`），不要混用两条写路径。

## dnfile / IL 扫描坑

- `pe.get_data_at_rva` 不存在——用 `pe.get_offset_from_rva` 后切 `pe.__data__`。
- `UserStringHeap.get` 要传 **token 低 24 位**（`tok & 0xFFFFFF`），传全 token 报 "stream is too small"。
- `TypeNamespace` 是 HeapItemString（用 `str()` 或 `or ''` 处理，不能直接拼）。
- IL 手写解码必须用完整 opcode 长度表：FE 前缀（FE06/07/15/16/18/19/1B 记 +4，FE09-0E 记 +2，FE12 记 +1）、switch(0x45)=5+4n、0x2B-37=2、0x38-44=5；**遇未知 opcode 直接 raise 而不是默认 +1**，否则 ldstr 站点漏报/误报。完整表见 `scripts/scan_ldstr.py`。
