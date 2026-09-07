---
name: "unity-game-localization"
description: "Unity 游戏文本汉化 via unity-assets MCP：定位 .assets 内脚本化对白与 UI 文本（GameCreator Dialogue/Variables、TextMeshProUGUI/UI.Text、DamageNumbersPro、Utage、Fungus 等载体），提取后用 translate_batch（本地 LLM 服务）批量译为简体中文并 import_json_batch 回写；另覆盖 Assembly-CSharp.dll 硬编码文本（dnSpy MCP + dnfile #US 堆原地补丁）。用户要求汉化/hanhua/翻译/本地化 Unity 游戏对白或资源文本时使用。"
---

# Unity 游戏文本汉化（unity-assets MCP）

使用 `unity-assets` MCP 服务器，把 Unity 游戏内脚本化文本（对白、UI 文案、伤害数字弹出文本等）定位、提取、批量翻译为简体中文并写回 `.assets` 文件；另覆盖程序集内硬编码文本补丁。依赖增强工具 `scan_text` / `locate_text` / `translate_batch` / `import_json_batch` / `list_script_types` / `export_all`；若 MCP 缺这些工具，退回文末「旧流程回退」。

**按需读参考文件**（渐进披露，到达对应阶段必须先读，保证知识等价）：

| 时机 | 文件 |
| --- | --- |
| 提取/分类/回写前**必读** | `references/class-fields.md`——脚本类→文本字段字典、text/name/format/review/tech 分类法 |
| `list_script_types` 出现大量 `Utage.*` 类，或 Managed 目录有 `Fungus.dll` | `references/engines.md`——两引擎专项定位与提取规则 |
| 遇到报错、静默失败、编码乱码、响应溢出 | `references/traps.md`——工具行为陷阱与排查 |
| assets 全部回写后界面仍有未汉化文本 | `references/dll-patch.md`——程序集硬编码文本补丁 |

## 适用触发

- 用户要求汉化/翻译 Unity 游戏文本（对白、对话、UI 文案）
- 文本存在 MonoBehaviour 的序列化字段里（GameCreator 脚本、自定义脚本、TMP 组件）

## 前置条件

- unity-assets MCP 需含上述增强工具（否则走旧流程）；`translate_batch` 依赖本地 LLM 翻译服务（默认 `http://127.0.0.1:51821/api/translate`，与 XUnity.AutoTranslator LLMTranslate 端点同协议）
- **gameId 必须显式传参**：MCP 进程 BaseDirectory 不确定时读不到 `translate_config.json`（也可从 `BepInEx\config\AutoTranslatorConfig.ini` 的 `[LLMTranslate] GameId=` 读取）；服务无配置时可传任意标识串
- 工具参数一律 camelCase（`pathId`/`typeId`/`scriptIndex`）；`close_file` 参数是 `name`；`save_file` 必填 `output`（覆盖源文件时 output=源路径）；`list_script_types` 的 `outputFile` 目录须先存在

## 工作流程

### 1. 前置准备

1. `open_file` 打开目标 `.assets`（level 场景 / sharedassets 等；多文件用 `open_files`）。v1.4+ 同目录有含 Assembly-CSharp.dll 的 Managed/ 时自动配 Mono 生成器（响应 `monoGenerator:"auto(mono)"`），Mono 构建可跳过第 2 步；为 `null` 说明 IL2CPP 或未探测到，需手动第 2 步。
2. **硬约束：解析 MonoBehaviour 前必须配置生成器** `set_mono_generator`——Mono 构建 `kind=mono` + `managedDir=<游戏 Managed 目录>`；IL2CPP 构建 `kind=il2cpp` + `metadataPath=<global-metadata.dat>` + `assemblyPath=<GameAssembly.dll>`。未配置时 import/export 会按通用模板产出损坏数据（v1.3+ 服务端直接报错拒绝，先设生成器再重试），读路径返回通用模板或大量 skipped。
3. `list_script_types file=<文件> keyword=<类名片段>` 查脚本类并**记录 scriptIndex**（keyword 按命名空间/类名过滤防响应截断；仍需全量列表时用 `outputFile` 落盘只返回统计）。

> MCP 重启后内存清空：需重新 `open_file`（v1.4+ 自动恢复 Mono 生成器；IL2CPP 需重设），否则 MonoBehaviour 全部 skipped、scan_text 结果为 0。
> `open_file`/`open_files` 会一直持有文件句柄：把游戏文件交给外部工具（XUnityToolkit 字体替换、打包备份、改 dll）前**必须 `close_all`**，否则外部写入/移动报 `UnauthorizedAccessException: Access to the path is denied`。

### 2. 文本池摸底（通用游戏的快速摸底/提取，推荐替代盲导出）

1. `open_files(paths[])` 一次打开全部 level/sharedassets/resources。
2. **survey 摸底**：`extract_pool(files="level0,level1,...")`（leaves 省略）返回跨文件 `类|叶子字段` 分组计数——对照 class-fields.md 把文本叶子定为白名单、技术字段排除（对任何 Mono 构建游戏通用，换游戏只换白名单）。**注意大计数的 `Array` 组**：自定义类 `string[]` 直接元素（对白池/词池/提示行）leaf 一律为 `Array`，是最常见的隐藏文本载体，必须抽查内容定性（文本→入白名单；同时排查同名组的 tech 值）。
3. **extract 出池**：`extract_pool(files=..., leaves="storyText,nameText,m_Text,m_text,description,m_Script", outPool="...pool.jsonl")`——内置噪声过滤（已含 CJK/纯数字/GUID/URL/短串），按原文去重写 JSONL（uid/text/count/locations，locations 自带回写定位键）。
4. 批量写回用 `save_files(files[])`（等价逐个 save_file(f,f)）。

边界：TextAsset 整体作为单条收集（fieldPath=m_Script）；数据表 JSON 的键级提取（itemName/description 等）是内容感知操作，按表结构单独处理（Fungus 类游戏见 engines.md）。

### 3. 定位与统计

1. **确定实例分布**：对 `<GameDir>_Data` 下所有 `.assets`/场景文件逐一 `list_script_types outputFile=<路径>` 落盘（目录须先存在），按 `className`/`pathId` 定位脚本定义所在文件。类型表只列该文件资产实际引用的脚本 → **只有类型表含目标类的文件才可能含有实例**。
2. **筛文本载体类**：对照 class-fields.md 筛出文本相关脚本类（不确定的按其分类法归入 text/name/format/review/tech），确定要枚举/导出的 scriptIndex；出现大量 Utage/Fungus 类先读 engines.md。
3. `list_assets typeId=114 scriptIndex=<N>` 枚举实例/评估规模（Dialogue 类常达数百实例）；`scan_text scopes=component|mono language=chinese|english limit=<N>` 统计中英分布（超 limit 用 `offset` 分页，看 `hasMore`）。
4. 已部分汉化的游戏：按 `[\u4e00-\u9fff]` 跳过中文统计剩余英文（往往很少），先向用户报告中/英/空分布再动手。
5. 规模大（数百实例/上千条）：向用户确认**先试点再全量**还是直接全量。

### 4. 导出与提取（本地脚本）

1. `export_all file=<文件> typeId=114 scriptIndex=<N> format=json outputDir=<目录> summaryOnly=true` 批量导出实例（summaryOnly 只返回统计，避免撑爆响应）。文件名 `{名称}-{源文件名}-pathid<pathId>.json` 末尾 `pathid<N>` 即回写定位键，`import_json_batch` 直接可用，**无需另行记录 pathId 映射**（名称段：有名资源用 `m_Name`、无名 MonoBehaviour 用 MonoScript 类名如 `TextMeshProUGUI`；改稿时名称段随意改，只保留末尾 `-pathid<N>`）。
2. **兜底扫描**：全量递归扫导出 JSON 的 `references.RefIds[].data`（只扫 data，不扫 type/asm 等元数据），能发现目标提取遗漏的文本载体（如 Dialogue 的 `GetStringString` → `data.m_Value` 物品/称号名），避免只译对白漏了物品名。
3. **本地提取**：只取目标脚本类的文本字段（字段路径查 class-fields.md），按原文去重，输出 JSON Lines（**必须 JSON Lines，不能用明文行**——多行对白/含换行译文会破坏行对齐）；统计 total/cn/en/sym/empty 分布向用户汇报。骨架：`scripts/extract_unique_en.ps1`。

### 5. 分类（先让用户决策）

提取后做统计分析（重复值、短串、含人名），识别以下类别，**让用户决策是否翻译**：

- **不译（翻译会破坏游戏逻辑）**：逻辑/事件标识符——变量名（`Cash`/`Lock-Game`）、信号名（`FadeInBlack`）、按钮触发器（`Normal`/`Highlighted`）；**枚举/比较共用串**（同一串既显示又参与 `ToString()==` 比较，如 `'All'`/`'Sword'`/`'Top'`）一律禁译。
- **保留英文**：测试/占位文本（`New Text`/`uwu`）、用户名/昵称（`player123`）、URL/路径/密码掩码、纯数值/货币/百分比（`$500K`/`60%`）、品牌/型号名、花括号模板（`{PC}`/`{M}` 运行时替换）。
- **角色名/专名**：跨文件**复用已有译名表**（此前汉化生成的 en\tzh TAB 分隔 UTF-8），新角色名按同样风格音译；注意**同名歧义**（老虎机符号 `Bar`→"条" vs 场所 `Bar`→"酒吧"），按文件/场景判断，必要时单独覆盖。
- **成人向词条**：性暗示/成人主题的道具、服装、状态名——询问用户：直译 / 委婉雅化 / 保留英文。
- **其余对白/描述/UI 标签**：翻译。

> **风格一致性**：游戏若已被部分汉化，先抽查已译内容确立风格（口语化/粗口/术语译法），翻译结果要与之一致。可用本地 LLM 先小批量试译几条向用户确认质量。

### 6. 批量翻译（translate_batch / 直连 HTTP 回退）

1. `translate_batch(inputFile=unique_en.jsonl, outputFile=unique_zh.jsonl, from=en, to=zh, gameId=<id>, autoRetryMiss=true)`——内部自动切块 + 并发 + 失败重试，`autoRetryMiss=true` 自动检测漏译（译文为空或与原文相同）。
2. **MCP 客户端调用约 30 秒超时，几千条必超** → Python 直连 HTTP（协议 `POST {"texts":[...],"from","to","gameId"}`，线程池并发 + 分块 + 断点续跑），骨架 `scripts/translate_direct.py`。先 curl 探测服务可用；并发以用户告知为准（MCP 工具上限 32；直连实测 10 条/请求 × 50 并发 ≈ 7 分钟/500 条）。
3. **结构化漏译重试**：从 en→zh 字典取漏译条目**整串**重试一轮（LLM 有随机性，实测可救回 ~88%）。漏译清单必须存 JSON/JSONL，禁止明文行。
4. **人工补翻**：重试后剩余逐条人工翻译（多为成人内容被服务端过滤的台词 + 拟声/特殊排版）；保留项（纯符号、按键名、开发占位）映射为自身。人工译表存独立文件便于改稿重跑。
5. **一致性检查**：抽查 `{wi}`/`<color>` 等标签是否保留、人名音译是否全程一致（端点不支持术语表，人名靠 LLM 上下文音译）；标签丢失即打回重翻。

### 7. 回写与验证

1. **本地映射回写**：读 to_translate jsonl 对构建 en→zh 字典，遍历导出 JSON 替换目标字段（仅当 `$dict[$t] -ne $t` 才写盘）。写入字段路径与提取用同一份映射（class-fields.md），防漏改。用 Python `json.dump` 或 Newtonsoft.Json；**禁 PS5.1 `ConvertTo-Json`**（解包单元素数组破坏结构，详见 traps.md）。骨架：`scripts/writeback.ps1`。
2. **三个静默漏替换坑**（均无任何报错，必须靠第 5 步残留审计抓回）：
   - 字典 key 是 strip 过的池文本，而 JSON 原文可能带前导换行/空格（Fungus Say.storyText 常见）→ 匹配必须用 `s.strip()` 查字典（实测 92 处因此失败）；
   - 数组元素路径末段是 `Array[0]` 而非 `Array` → leaf 归一化统一用 `re.sub(r'\[\d+\]$', '', path.split('.')[-1])`（实测 26 处对白漏写）；
   - 单词技术键（'speed'/'critical'/'max'/'attack'/'weak' 等）可能经 EventTrigger/Button 的 m_StringArgument 混进字典被 LLM 译出 → 回写字典强制过技术键黑名单，误译写回会破坏游戏逻辑。
3. **批量回写**：`import_json_batch file=<文件> jsonDir=<导出目录> skipUnchanged=true`；v1.3+ 默认 summary 模式（返回计数 + failedItems 明细，逐条明细用 `details=true` 配 limit/offset 分页）；success 数应与本地 changedFiles 数一致（分文件合计）。save_file 后 MCP 内存即最新状态，无需重新 open 即可扫描。
4. **先测试副本再落真实文件**：复制真实文件到工作目录 → `open_file` → import → `save_file` → 重新 `scan_text` 验证中文生效（英文关键词 count=0、中文关键词 >0；重扫目标字段，剩余英文应全在 keep 列表，**unexpected_miss=0**）。注意 scope 语义：TMP/UI.Text 文本在 `component` scope，Fungus.Say 等非 UI 组件在 `mono` scope，不确定就省略 scopes（默认全开），否则会误判"替换丢失"。确认无误后**先备份真实文件**（`Copy-Item` 到 `.bak`；用户可能已删旧备份，需确认）→ 对真实文件 import → `save_file`；对比测试副本与真实文件 MD5 一致。
5. **终验残留分类**：重扫全部显示字段，按合理保留项（纯符号 ▶◀×▼、按键名 SHIFT/Z、运行时模板 `HP：99.9`/`resource(amount)`、Lorem ipsum、剧情性拟声乱码）过滤后逐条过目，**其余英文残留应为 0**，否则回补漏（多为多行文本 CRLF/LF 差异、strip 差异、特殊引号 `\u2019`——从原 jsonl 精确复制原文比对）。
6. **交接外部工具前释放文件锁**：assets 流程结束、或后续由外部工具接管时 `close_all`；之后如需再扫描，重新 `open_file` 即可。

### 8. 全量字符串差集审计（assets 提取完成后必做一次）

1. 把**所有**导出 JSON（全部 level/sharedassets/resources 的 typeId=114）里的字符串递归收集，与已提取集合（对白/角色名/UI 文本）做差集。
2. 差集按 (类 × 叶子字段名) 分组统计，**从大到小逐组过目**：触发器名/方法名/Tile 名/消息键等技术组直接排除；`m_StringArgument`、`description`、`slotName`、`*Serif` 等可疑组逐条看值甄别。可直接用 `scan_text groupBy="scriptClass,fieldPath"` 服务端聚合（响应仅几 KB）。
3. 对每个文件 `list_assets typeId=49` 检查 TextAsset 是否只在已知文件；`export_all` 报 failed 的实例用 `get_asset_info` 查明身份（可能只是语音/技术数据）。
4. 未导出过的小文件（level12、sharedassets* 等）也要补导一次确认为空。
5. 最后做 dll 硬编码扫描（dll-patch.md），报告剩余可见文本总量。

## 必须询问用户的决策点

| 决策 | 要点 |
| --- | --- |
| 翻译范围 | 仅对白/变量文本，还是含 UI 组件文本（`scopes=component`），或全部 string（不推荐，破坏逻辑） |
| 执行方式 | 先试点（选 1-2 个实例跑通全流程）再全量，还是直接全量 |
| 翻译风格 | 口语化保真（保留粗口/成人向）或温和雅化——内容尺度大时差异明显 |
| 分类保留 | 用户名/URL/数值/品牌名/角色名/测试占位 哪些保留、哪些翻译 |
| 已汉化游戏的补漏 | 大部分已中文时只翻译剩余英文（`[\u4e00-\u9fff]` 跳过中文），向用户确认保留项分类（金额/占位符/测试文本/符号/彩蛋等） |
| 成人内容 | 性暗示/成人主题词条：直译 / 委婉雅化 / 保留英文 |
| 写回方式 | save_file 覆盖源文件不可逆 → 先备份（用户可能删除过旧备份，需确认后新建） |
| 未翻译处理 | 重试无效的漏译条：人工翻译 / 保留英文 |

## 参考文件与脚本

| 文件 | 内容 |
| --- | --- |
| `references/class-fields.md` | 脚本类→文本字段字典、字段分类法（含优先级规则与确切映射）、提取分类器要点 |
| `references/engines.md` | Utage（剧本 book/语言表/行级规则）与 Fungus（Say/Character/Conversation/TextAsset 数据表）专项 |
| `references/traps.md` | 工具行为陷阱：文件锁、MRR 数组、响应溢出护栏、missing script、PS5.1 三坑、编码判定等 |
| `references/dll-patch.md` | Assembly-CSharp.dll 硬编码文本：dnSpy MCP 定位 + #US 堆原地替换回写 |
| `scripts/` | `extract_unique_en.ps1`（提取/分类/合并）、`writeback.ps1`（映射回写/补翻/兜底扫描）、`translate_direct.py`（直连翻译+Fungus 回写）、`scan_ldstr.py`（程序集 ldstr 扫描）、`patch_us_heap.py`（#US 补丁骨架） |

## 旧流程回退（MCP 缺增强工具时）

- 翻译：人工逐条翻译（或本地脚本直接 HTTP 调翻译服务，自行实现切块/并发/重试与 JSON Lines 输出）
- 回写：逐个 `import_json(file, pathId, jsonPath)` 分批完成（百个实例约十余批），再 `save_file`
- 提取/映射脚本同 `scripts/`

## 说明

本 skill 只描述可复用的工作流。不要在其中写入具体游戏的 pathId、昵称、译文等任务数据——每次执行时按流程现场提取。游戏名、翻译风格、是否含成人内容等需在执行中询问用户。
