# 工具行为陷阱与排查（按症状查）

主流程各步骤使用点上的高频坑（Mono 生成器、JSON Lines、strip 匹配、scope 语义、30 秒超时）已写在 SKILL.md 对应步骤；本文件收其余独立陷阱，遇到报错、静默失败、数据异常时按症状检索。

| 陷阱 | 现象/原因 | 对策 |
| --- | --- | --- |
| `set_field` 改不了 MRR 数组内字段 | 点路径无法触达 `references.RefIds[].data` 内部 | 必须 `import_json` / `import_json_batch` 整体 JSON 回写 |
| `read_tree` 输出截断 | 单实例输出可达数十 KB | 一律 `export_all summaryOnly=true` 导出到磁盘本地处理 |
| **PS5.1 脚本三坑** | ①`ConvertTo-Json` 解包单元素数组破坏嵌套结构，生成 jsonl 也会损坏；②给 JToken 赋中文直接 `$j['field']=$str` 走 JToken.Parse 报 "Unexpected character"；③无 `Join-String`、脚本正文中文注释 GBK 解析崩溃、`ConvertTo-Json` 深层结构截断、`$pid` 是保留变量 | ①改用 Newtonsoft.Json.dll（从游戏 `BepInEx\plugins\...` `Add-Type` 加载）：`JObject.Parse` 修改、`ToString()` 写盘；②赋字符串必须 `[Newtonsoft.Json.Linq.JValue]::new($str)` 显式包装；③用 `-join`、脚本正文避免中文（数据放外部 UTF-8 文件或 `[char]0xXXXX`）、`-Depth 100`、换变量名 |
| 翻译 JSON 内嵌未转义双引号 | 解析失败 | 用中文引号规避 |
| `resources.assets` 噪声与误判 | ①混有 Unity 内置调试 UI prefab（`DebugUIHandler*` 脚本、文本 `New Text`/`wibble`/`TEST`），scan_text 会命中但非游戏文本；②也可能全是字体/引擎资源（TMP_FontAsset/StyleSheet/Emoji），扫到噪声误导统计 | ①统计与翻译都应排除调试 prefab；②以"该文件的脚本类型表含哪些游戏文本类"为准判断有无文本，**别按文件大小猜** |
| **脚本映射文件名不一致** | `list_script_types outputFile` 落盘名与源文件名不一一对应（`resources.assets`→`resources.assets.json`，而 `level0`→`level0.json`、`sharedassets1.assets`→`sharedassets1.json`） | 本地建 m_Script→类名映射时按 `{src}.json` 和 `{src}.assets.json` 两个候选依次找；只试一个会把整个文件的字符串全判成 `?` 类而漏提取（曾致 137 条 UI Text 全漏） |
| walk 生成路径带前导点 | 递归 `path+'.'+k`，顶层字段路径是 `.nameText` 而非 `nameText`；直接 `field=='nameText'` 全等比较会 0 命中 | 分类匹配用 `path.split('.')[-1]` 取叶子，或 strip 前导点 |
| **客户端 50KB 响应预算与溢出护栏** | 客户端对单条工具响应超约 50KB 会按字节硬切（静默、产出非法 JSON）；服务端已在 `Json()` 加护栏：超 40KB 自动把完整结果写入 `%TEMP%\unity-assets-mcp-spill\resp-*.json`，响应改为 `{guard:"spilled_to_file", fullResultFile, originalBytes, preview}` | 看到 `guard:"spilled_to_file"` **不要重试原调用**——数据零丢失在文件里，用 Read 分页读取 fullResultFile；更优做法是改用工具的 summary/分页参数缩小响应。升级服务端后客户端会话内的工具 schema 是缓存的旧版（新参数不可见），需重启会话/客户端生效；stdio 直连测试时 printf 会把 `\\\\` 折叠成 `\` 导致请求 JSON 非法——用 Python json.dumps 构造请求 |
| **未设生成器时 skipUnchanged 误报** | 生成器缺失时 import 按通用 MonoBehaviour 模板重写数据（v1.3+ 已加防护直接拒绝）；防护前的内存态/落盘即损坏，且 skipUnchanged 把差异误报为"变更" | 遇 import/export 拒绝报错先 `set_mono_generator` 再重试；读路径（read_tree/read_field/scan）无防护但同样需要生成器 |
| **missing script 类 → MonoCecil 模板生成 NRE** | 开发者删类后遗留的组件（或混淆器改名）：MonoScript 的 className 在全部程序集中搜不到 → 模板生成抛 NullReferenceException（信息为空），read_tree/export_all(json)/extract_pool 对该资源失败 | v1.4+ 失败时抛带 `file/pathId/scriptClass/常见原因` 的 McpException；`extract_pool` 响应带 `readFailItems` 可精确定位。定性：`export_raw` 读原始字节 + dnSpy `search_types` 全程序集搜类名（缺失 = missing script）。此类资源通常无文本（遗留数值），计入 readFail 即可 |
| **客户端对慢调用疑似超时重试** | 14 文件批量 open_files 首次响应显示全部 `already-configured`——与"首个文件应 auto(mono)"矛盾；推断客户端超时后在同一服务实例上重试，第二次响应覆盖第一次 | 批量工具必须幂等（open_files/import 重复执行无害）；验证 auto(mono) 等一次性标记时用强制重启后的**单个** `open_file`；长调用尽量拆分或落盘 |
| 终端"乱码"假象 | Git Bash `cat`/`head` 按本地代码页显示 UTF-8 文件，日文内容看似 GBK 乱码（`锘]锝...`） | 判定文件编码用 Python `raw[:3]` 看字节 + 显式 `decode('utf-8-sig')` 验证，**不要相信终端显示** |
