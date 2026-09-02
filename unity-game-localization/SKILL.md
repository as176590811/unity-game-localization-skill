---
name: "unity-game-localization"
description: "Unity game text localization via the unity-assets MCP server: locate script-based dialogue (e.g. GameCreator Dialogue GetStringTextArea/GetStringString, LocalListVariables, TextMeshProUGUI, DamageNumbersPro.DamageNumberGUI popups, Utage visual-novel scenario books/LanguageManager tables, Fungus engine Say/Conversation/Character + JSON data tables), extract, batch-translate to Simplified Chinese via translate_batch (local LLM service), and write back to the .assets file with import_json_batch. Also covers hardcoded strings inside Assembly-CSharp.dll (dnSpy MCP + dnfile #US-heap scan, in-place patch write-back). Invoke when user asks to translate/hanhua/localize Unity game dialogue or asset strings."
---

# Unity 游戏文本汉化（unity-assets MCP）

使用 `unity-assets` MCP 服务器，把 Unity 游戏内脚本化文本（对白、UI 文案、TextMeshProUGUI、伤害数字弹出文本等）定位、提取、批量翻译为简体中文并写回 `.assets` 文件的完整工作流。典型场景：GameCreator 系组件（`Dialogue` 的 `GetStringTextArea` 对白 / `GetStringString` 物品称号名、`LocalListVariables` / `LocalNameVariables` 的 `ValueString`）、Unity UI 文本组件（`TextMeshProUGUI` / `TextMeshPro` / `UI.Text` 的 text 字段）、DamageNumbersPro 的 `DamageNumberGUI` 弹出文本（topText/leftText/rightText/bottomText）、Utage 视觉小说引擎（`AdvImportBook` 剧本对白、`LanguageManager` 本地化表、TMP UI 文本，见 §2b）、Fungus 引擎（`Say`/`Conversation`/`Character` 对白、TextAsset JSON 数据表、场景序列化台词，见 §2b+）、以及 **Assembly-CSharp.dll 内硬编码 UI 文本**（dnSpy MCP + dnfile 定位、#US 堆原地替换回写，见 §7）。

**本流程基于 unity-assets MCP 的增强工具**（`scan_text` / `locate_text` / `translate_batch` / `import_json_batch` / `list_script_types` / `export_all`），可将数万条文本全自动批量翻译回写。若 MCP 未升级（缺这些工具），退回旧流程（附录 C）。

## 适用触发

- 用户要求汉化/翻译 Unity 游戏文本（对白、对话、UI 文案）
- 文本存在 MonoBehaviour 的序列化字段里（GameCreator 脚本、自定义脚本、TMP 组件）

## 前置条件

- unity-assets MCP 版本需含：`scan_text`（含 offset 分页）、`locate_text`、`translate_batch`（含 autoRetryMiss）、`import_json_batch`（含 skipUnchanged）、`list_script_types`（含 keyword/outputFile）、`export_all`（含 summaryOnly）
- `translate_batch` 依赖本地 LLM 翻译服务（默认 `http://127.0.0.1:51821/api/translate`，与 XUnity.AutoTranslator LLMTranslate 端点同协议，请求体 `{"texts":[...],"from","to","gameId"}`）
- gameId 优先显式传参（MCP 进程 BaseDirectory 不确定时 `translate_config.json` 可能读不到）

## 核心流程

### 1. 前置准备

| 步骤         | 操作                                                                                                                                                                         | 要点                                                                                                                           |
| ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| 1. 打开文件    | `open_file` 打开目标 `.assets`（level 场景 / sharedassets 等）                                                                                                                      |                                                                                                                              |
| 2. 设置模板生成器 | `set_mono_generator`：Mono 构建 `kind=mono` + `managedDir=<游戏 Managed 目录>`；IL2CPP 构建 `kind=il2cpp` + `metadataPath=<global-metadata.dat>` + `assemblyPath=<GameAssembly.dll>` | **必做**，否则脚本字段无法解析，scan_text 会 skipped 大量资源                                                                                   |
| 3. 查找脚本类   | `list_script_types file=<文件> keyword=<类名片段>`                                                                                                                               | `keyword` 按命名空间/类名过滤避免脚本类型多时响应截断（如 `keyword="TextMeshPro"` 一步定位 TMP 类）；**记录 scriptIndex**；仍需全量列表时用 `outputFile=<路径>` 落盘只返回统计 |

> 注意：MCP 重启后内存清空，需重新 `open_file` + `set_mono_generator`（否则 MonoBehaviour 全部 skipped，scan_text 结果为 0）。

### 2. 定位与统计

| 目的                          | 方法                                                                                                                                               | 要点                                                                                                           |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------ |
| 确定实例分布                      | 对 `<GameDir>_Data` 下所有 `.assets`/场景文件逐一 `list_script_types outputFile=<路径>` 落盘（**目录须先存在**），按 `className`/`pathId` 定位脚本定义所在文件                     | 脚本类型表只列**该文件资产实际引用的脚本**（场景中 MonoBehaviour 经 fileId 引用定义在 sharedassets 里的 MonoScript）→ **只有类型表含该类的文件才可能含有实例** |
| 筛文本载体类                      | 类型表落盘后对照 **§2c 速查表**筛出文本相关脚本类（不确定的类按 **§2d 字段定位分类法**归入 text/name/format/review/tech），确定要枚举/导出的 scriptIndex；**类型表出现大量 `Utage.*` 类 → 先走 §2b 专项定位** | 速查表是"类→字段"字典，§2 选类、§3 提取、§6 回写三处都要对照使用                                                                       |
| 枚举实例/评估规模                   | `list_assets typeId=114 scriptIndex=<N>`                                                                                                         | 返回 pathId、字节大小；Dialogue 类常达数百实例                                                                              |
| 统计 UI 文本中英分布                | `scan_text file=<文件> scopes=component language=chinese\|english limit=<N>`                                                                       |                                                                                                              |
| 扫全部 MonoBehaviour string 字段 | `scan_text scopes=mono`                                                                                                                          | 返回的 `scriptClass`/`fieldPath` 对照 **§2c 速查表**分辨文本字段与技术字段；成体系的全量分类用 **§2d 字段定位分类法**                            |
| 结果超过 limit 翻页               | `offset` 分页（如 `offset=200&limit=200` 取第二页）                                                                                                       | 响应含 `hasMore`/`collected` 判断是否还有更多                                                                           |
| 已部分汉化的游戏                    | 按 `[\u4e00-\u9fff]` 跳过中文统计剩余英文                                                                                                                   | 剩余英文往往很少——先向用户报告中/英/空分布再动手                                                                                   |
| 规模大时                        |                                                                                                                                                  | 数百实例/上千条：向用户确认**先试点再全量**还是直接全量                                                                               |

### 2b. Utage 引擎专项定位（视觉小说）

触发特征：`list_script_types` 出现大量 `Utage.*` 类（`AdvEngine`、`AdvScenarioPlayer`、`AdvUguiMessageWindowTMP`、`TextMeshProNovelText` 等）。

**载体与数据链**（`list_script_types` 查 scriptIndex → `list_assets typeId=114 scriptIndex=<N>` 枚举实例）：

| 载体（脚本类/资产）                                                                                                                            | 定位特征                                                                              | 字段/文本位置                                                                                                                       | 处理规则                                                             |
| ------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------- |
| `Utage.AdvImportScenarios`                                                                                                            | 实例体积小（几十字节）                                                                       | `chapters` → PPtr 引用 `AdvChapterData`                                                                                         | 仅引用无文本，顺链下钻                                                      |
| `Utage.AdvChapterData`                                                                                                                | 实例几 KB                                                                            | `chapterName`；`settingList.Array[].rows[].strings.Array`（各 Setting 表）；`dataList` → PPtr 引用 `AdvImportBook`                    | Param 表的 `saveTitle` 等字符串值可译；经 `dataList` 定位剧本主体                 |
| `Utage.AdvImportBook`（"xxx.book"，**剧本主体**）                                                                                            | 实例体积 MB 级，看 size 即识别（不必 read_tree）；IL2CPP 版常**无 StreamingAssets**，内嵌 sharedassets | `importGridList.Array[]` 每个 sheet 一个场景 label（`name` 形如 `Assets/.../xxx.xls:<label>`）；行 = `rows.Array[].strings.Array`（TSV 网格） | 行级提取规则见下表                                                        |
| `Utage.LanguageManager`                                                                                                               | 实例小                                                                               | `language`/`defaultLanguage`/`dataLanguage`（语言状态）；`languageData` → PPtr 引用 TextAsset 本地化表                                     | 语言状态是"已译/未译"判断基准；**对白与 UI 语言可能不一致**（如对白仅英文一份、UI 日英双语），分布要按载体分开统计 |
| 本地化 TextAsset 表                                                                                                                       | `list_assets typeId=49` 枚举 → `export_all typeId=49` 导出                            | `m_Script` 文本 = `Key\t<语言1>\t<语言2>` TSV（常带 UTF-8 BOM）                                                                         | 按 Key 解析各语言列；`UguiLocalize.key` 对应 Key 列                         |
| `Utage.UguiLocalize`                                                                                                                  | 场景内大量实例                                                                           | `key` 字段                                                                                                                      | 本地化键，**技术值不译**，可作 UI 文本归属参考                                      |
| Utage TMP 包装类（`AdvUguiMessageWindowTMP` / `TextMeshProNovelText` / `TextMeshProRuby` / `AdvUguiSelectionTMP` / `AdvUguiBacklogTMP` 等） | —                                                                                 | 自身**无序列化文本**，只引用 TMP 组件（`UguiIndexTextTMP` 仅 `formatIndexText` 模板）                                                            | 直接导出 `TMPro.TextMeshProUGUI` + `UnityEngine.UI.Text` 覆盖其显示文本     |

**AdvImportBook 行级提取规则**：

| 行类型      | 识别方式                                                                                   | 提取规则                                                                                                                     |
| -------- | -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| 表头行      | `strings[1]=='Command'`                                                                | **必须跳过**，否则表头词（`Text`/`Voice`）混入文本                                                                                       |
| 对白行      | `strings[1]` 为空 且 文本列非空                                                                | 文本列索引**从表头行读取、不要写死**（典型 `['', 'Command','Arg1'..'Arg6','WaitType','Text','PageCtrl','Voice','WindowType']` → Text 列 = 9） |
| 命令参数显示文本 | `strings[1]=='SendMessageByName'` 等命令的参数列（SendMessageByName = 向指定名称组件发送字符串参数，用途由游戏自定义） | 参数可能是显示文本（有游戏用作成就名）也可能是技术值（BG 名/角色名/`None`/`0`）——**逐条甄别，勿套用单一正则**：含空格的可读短语优先人工确认，单词/数字多为技术值                              |
| 占位符      | 对白文本中 `<param=xxx>`                                                                    | 运行时替换角色名/参数，翻译需保留                                                                                                        |

### 2b+. Fungus 引擎专项定位

触发特征：Managed 目录有 `Fungus.dll`；`list_script_types` 出现 Fungus 类（`Flowchart`、`Say`、`Character`、`Conversation`、`Block`、`SayDialog`、`MenuDialog`、`MessageReceived`、`Stage`、`View`、`Writer`、`Localization`）。注意 **Fungus 命令对象（Say/Menu 等）不是 Flowchart 的子对象，而是与 Flowchart 同文件的独立 MonoBehaviour**，由 Flowchart 的 commandList PPtr 引用——不能只看 Flowchart 实例大小。

**载体与数据链**：

| 载体 | 定位特征 | 字段/文本位置 | 处理规则 |
| --- | --- | --- | --- |
| `Fungus.Say` | 每条对白一个实例（几百字节），主场景可达数千 | `storyText`（对白主体）；`character` PPtr → `Fungus.Character`；`description`（编辑器备注，一般不译） | 主对白库；按 `itemId` 可排序还原剧情顺序 |
| `Fungus.Character` | 场景内几十个 | `nameText`（说话人显示名） | 角色名；`character` PPtr 的 m_PathID 反查 nameText 得到每条对白的说话人 |
| `Fungus.Conversation` | 少量 | `conversationText.stringVal`，格式 `"角色名 Part:文本"`（Part ∈ Unknown/Middle/Bottom 等） | 整串需按第一个空格与 `Part:` 拆分，保留结构只译文本段 |
| `Fungus.Block` | 每个 Block 一个 | `blockName`（**技术值不译**）；`description`（本游戏存章节/剧情标题，如 "A Night of Secrets"） | description 是编辑器元数据，**是否在游戏内显示需实测**（可能用于章节选择/存档标签），先提取为 review 类 |
| `Fungus.MessageReceived` | — | `message`（Fungus 消息事件键） | **技术值不译** |
| `Fungus.Localization` | 实例极小（几十字节）= 空表 | `stringTable` | 空表说明无多语言数据，全文本为单一语言 |
| `SayDialog`/`MenuDialog`/`Writer`/`Stage`/`View` | UI 外壳 | 自身无对白文本（`UguiIndexTextTMP` 仅 formatIndexText 模板） | 导出 `Text`/`TextMeshProUGUI` 覆盖其显示文本 |

**Fungus 游戏特有的其他文本载体**（依脚本类 × 字段甄别，参照 §2d 分类法）：

| 类 × 字段 | 类别 | 说明 |
| --- | --- | --- |
| `EventTrigger.m_StringArgument` | **review→text** | 可能是设施/属性悬停说明等显示文本，也可能是技术键（如 'speed'/'critical'）——**逐条按可读性甄别**，同一字段在不同 level 用途不同 |
| `Button`/`Slider.m_StringArgument` | tech | 方法参数键（状态 id、动画键等），不译 |
| 自定义 `*Manager` 类的 `*Serif` 字段（defaultSerif/equippedSerif/exchangeSerif/lockedSerif 等） | text | NPC 台词，序列化在场景实例里（.ctor 里的默认值会被场景值覆盖）；同类还有 `slotName`（EquipSlot 装备槽名）等 |
| `ItemButton`/`EquipManager` 等的 `statsToStr` 映射 | tech | 'hp'/'power' 等小写键为**逻辑比较键**；对应显示串（'HP'/'ATK' 等）若是独立 ldstr 才可译 |
| **枚举/比较共用串**（`'All'`、`'Sword'`、`'Top'`、`'Weapon'`、`'Normal'` 等） | **tech 禁译** | 同一字符串既显示又参与 `ToString()==` 比较（如 enchant 稀有度键、装备槽比较）——凡该串出现在 switch/比较逻辑的方法里，一律不译 |
| TextAsset JSON 数据表（typeId=49） | text/name | Fungus+Lua 或数据驱动游戏常把物品/敌人/技能/通知/地名放 `resources.assets` 的 TextAsset（如 ItemData/enemyData/enchantData/facilityData/notificationData/castSerif），按 JSON 键名甄别 name/description/label 字段；`FungusTypes`/`UnityTypes`/LineBreaking 等为引擎表不译 |

**TextAsset 数据表处理规则**（实战踩坑汇总）：

1. **导出必须用 `export_text_asset_text`（逐 pathId）**，不要用 `export_all format=txt` 的 dump——dump 里的转义串二次解码会把非 ASCII 弄成乱码（`ã€【`），且对含转义的 JSON 会解析失败。
2. **游戏 JSON 常带尾逗号**（Newtonsoft 容忍、Python 不容忍）→ 解析前 `re.sub(r',\s*([}\]])', r'\1', s)`；含 `\"` 与字面 `\r\n` 转义属正常。
3. **先看内容再定性质**：同名 ".json" 可能是开发备忘录（如 tirasi 是日语设计笔记，排除）、场景键表（playLabelName/scenarioLabelName 的值是 `_1_3start` 类键，排除）或显示名表（playSceneName/scenarioSceneName 是 "Muscleman vs. Swordswoman" 类显示名，要译）——**键表与显示名表名字只差一个词，必须抽查值**。
4. **只收显示键**（itemName/name/description/label/names/effectDescription），effect/playType/moveType 等键是逻辑值；notificationData 整表都是对白行可直接全收。顶层以数字为键的 dict（playSceneName 的 "0"/"1"）提取时别把 leaf 判成数字键而漏收。
5. Conversation 的 `conversationText.stringVal` 格式实为 **"角色名 [姿势] [Part]:文本"**（如 `Angela 0_half L1:Ngh...`、`UNKNOWN Hide:`），**不要假设一定有 Part 关键字**——拆分点就是**第一个冒号**，前缀保留原样、只译冒号后的文本段，回写时重新拼装。

**Fungus 定位流程**：`list_script_types` 落盘全部文件 → 找含 `Say`/`Flowchart` 的 level → `export_all typeId=114` 全量导出该 level 的 MonoBehaviour → 本地按 m_Script pathId 映射类名、walk 全字段 → Say.storyText + Character.nameText + Conversation.stringVal + UI 组件文本 + TextAsset 表 → 去重成 unique jsonl。


### 2c. 脚本类文本结构速查

| 脚本类（脚本索引查 `list_script_types`）                                                                                                         | 文本位置                                                                                                                                                     | 结构示例                                                         |
| -------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| `GameCreator.Runtime.Dialogue.Dialogue`                                                                                                | `references.RefIds[]` 中 `type.class=="GetStringTextArea"` 的 `data.m_Text.m_Text`（对白主体）；`type.class=="GetStringString"` 的 `data.m_Value`（物品/称号/标签名、商店对白等） | 对白 + 物品/称号名                                                  |
| `DamageNumbersPro.DamageNumberGUI`                                                                                                     | 顶层字段 `topText`/`bottomText`/`leftText`/`rightText`（受 enableTopText 等开关控制）；`number`、`digitSettings.suffixes`（K/M/B/T）为数值格式**不译**                          | 伤害/粉丝/订阅弹出文本                                                 |
| `GameCreator.Runtime.Variables.LocalListVariables` / `LocalNameVariables`                                                              | `type.class=="ValueString"` 的 `data.m_Value`（字符串）                                                                                                        | 变量表文本                                                        |
| `Utage.AdvImportBook`（"xxx.book"）                                                                                                      | `importGridList.Array[]` 每个 sheet 一个场景 label；对白 = 数据行（`strings[1]` 为空）的 Text 列（索引从 sheet 首行表头读，典型 9；表头行 `strings[1]=='Command'` 跳过）                      | Utage 剧本对白（可含 `<param=xxx>` 占位符；命令参数列另有成就名等显示文本）；行级提取细则见 §2b |
| `Utage.AdvChapterData`                                                                                                                 | `settingList.Array[].rows[].strings`（Param 表的 `saveTitle` 等字符串值）；`chapterName`                                                                           | 章节名/存档标题                                                     |
| `Utage.LanguageManager`                                                                                                                | `language`/`defaultLanguage`（语言状态判断基准）；`languageData` → TextAsset 本地化表（`Key\t日文\t英文` TSV）                                                                | 系统文本双语表                                                      |
| `Utage.UguiLocalize`                                                                                                                   | `key`（本地化键，**技术值不译**，对应本地化表 Key 列）                                                                                                                       | UI 文本归属参考                                                    |
| `Utage.AdvUguiMessageWindowTMP` / `TextMeshProNovelText` / `TextMeshProRuby` / `AdvUguiSelectionTMP` / `AdvUguiBacklogTMP` 等 Utage 包装类 | 自身通常**无序列化文本**（引用 TMP 组件；`UguiIndexTextTMP` 仅 `formatIndexText` 模板）                                                                                      | 显示文本在 `TextMeshProUGUI`，导出 TMP 类覆盖                           |
| `TMPro.TextMeshProUGUI`（UI 文本，字段 `m_text` 小写）                                                                                          | `m_text`                                                                                                                                                 | 按钮/标签/聊天/邮件/教程文本                                             |
| `TMPro.TextMeshPro`（3D 文本，字段 `m_text` 小写）                                                                                              | `m_text`                                                                                                                                                 | 场景内 3D 文本                                                    |
| `UnityEngine.UI.Text`（字段 `m_Text` 大写）                                                                                                  | `m_Text`                                                                                                                                                 | 旧版 UI 文本                                                     |
| `Febucci.TextAnimator_TMP`（字段 `_text`）                                                                                                 | `_text`                                                                                                                                                  | 打字机动画文本                                                      |
| `GameCreator.Runtime.Common.UnityUI.ButtonInstructions`                                                                                | `references.ref[N].m_Value`（如 `Click!`）                                                                                                                  | UI 交互文本，可译                                                   |
| 各类脚本                                                                                                                                   | `m_Variable.m_Name.m_String`（变量名）、`m_Signal.m_String`（信号名）、`m_TypeID.m_String`（number/boolean）                                                           | **技术字符串，不译**                                                 |

通用判断：文本字段是 `type.class` 明确的字符串载体（`GetStringTextArea` / `ValueString`）或 UI 组件 text 字段（`m_text`/`m_Text`/`_text`），技术字段（变量名/信号名/触发器/资源名）一律跳过。

### 2d. 字段定位分类法（通用：按"叶子字段名 × 脚本类"分类）

实战提炼的通用规则:每条文本用**四元组 `file + pathId + scriptClass + fieldPath`** 定位：`file+pathId` 定位 assets 内资源（即 export_all 文件名末尾的 `-源文件-pathid<N>`），`fieldPath` 是导出 JSON 内的完整字段路径，回写按同一路径替换。对每个 string 按下表**优先级从上到下**分类为 `text`（可译）/ `name`（名称类，译名需一致）/ `format`（格式串，保留 `{0}` 占位符）/ `review`（混合，人工甄别）/ `tech`（技术值，禁止写回）：

| 优先级 | 规则                                                                                                                 | 类别        | 说明                                                                                                                                                                                                                                                                                                   |
| --- | ------------------------------------------------------------------------------------------------------------------ | --------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | `fieldPath` 末段命中 `.m_Variable.m_Name.m_String` / `.m_Variable.m_TypeID.m_String` / `.m_Signal.m_String`            | tech      | 变量名/类型名/信号名；GameCreator 资产里数量极大（常占全部 string 一半以上）                                                                                                                                                                                                                                                    |
| 2   | 值是 GUID（`8-4-4-4-12` hex）/16+ 位 hex 串/`Assets/...` 路径/URL 类（含 http 前缀，或无空格且形如 `域名/路径`、`scheme://...`，如 `xxx.com/Home`、`steam://...`；按钮/链接字段还可能塞密码字段值如 `password`）                                                      | tech      | 即使叶子名是文本字段                                                                                                                                                                                                                                                                                           |
| 3   | 叶子名 ∈ 通用文本叶子：`m_text`、`m_Text`、`_text`、`text`、`topText`、`bottomText`、`leftText`、`rightText`、`infoLeft`、`infoRight` | text      | 无论什么类出现都可译（UI 文本/伤害数字弹出/tooltip 左右栏）                                                                                                                                                                                                                                                                 |
| 4   | (类， 叶子) 命中 §2c 速查表或下方确切映射                                                                                          | text/name | 见下方补充映射                                                                                                                                                                                                                                                                                              |
| 5   | 类 ∈ {`GameCreator.Runtime.VisualScripting.Trigger`/`Conditions`/`Actions`} 且叶子 = `m_Value`                         | review    | 视觉脚本 value 载荷混合，细分甄别。保留：下划线开头驼峰（shader/材质属性名 `_FadeAmount`/`_Color`/`_Alpha`，常占 review 大头）、PascalCase 标识符（`TabletopHeroSelected`）、状态词（`Enable`/`Disable`/`Toggle`/`none`）。可译：星期（Monday…Weekend）、亲属/角色词（mom/Daughter）、含空格的可读短语与整句（`Tabletop Party Core`）                                                                                                                                                                                                                   |
| 6   | 其余                                                                                                                 | tech      | **默认拒绝**：ScriptableObject 的 `m_Name`、`m_MethodName`、`m_TargetAssemblyTypeName`、`m_ObjectArgumentAssemblyTypeName`、UI Selectable 系 `m_NormalTrigger`/`m_HighlightedTrigger`/`m_PressedTrigger`/`m_SelectedTrigger`/`m_DisabledTrigger`、InputActionAsset 的 `m_Id`/`m_Path`/`m_Action`/`m_Groups` 全是技术值 |

**(类， 叶子) 确切映射**（§2c 未覆盖的补充，经 GameCreator 2 商业游戏全量提取验证）：

| scriptClass                                                                              | 叶子字段                                                           | 类别          | 内容                            |
| ---------------------------------------------------------------------------------------- | -------------------------------------------------------------- | ----------- | ----------------------------- |
| `GameCreator.Runtime.Quests.Quest`                                                       | `m_Value` / `m_Name`                                           | text / name | 任务描述 / 任务名（`m_String` 为 tech） |
| `GameCreator.Runtime.Stats.Stat` / `.Attribute`                                          | `m_Value` / `m_Name`                                           | text / name | 统计项描述 / 统计项名                  |
| `GameCreator.Runtime.Stats.Class`                                                        | `m_Name`                                                       | name        | 职业名                           |
| `GameCreator.Runtime.Stats.Traits`                                                       | `m_Name`（`m_String`=tech）                                      | name        | 特质名                           |
| `GameCreator.Runtime.Dialogue.Actor`                                                     | `m_Name` / `m_Value`                                           | name        | 说话角色名                         |
| `GameCreator.Runtime.Common.UnityUI.TextPropertyString` / `.InputFieldTMPPropertyString` | `m_Value`                                                      | text        | UI 绑定字符串属性                    |
| `Fullscreen.NanoSave.Runtime.SaveSlotComponent`                                          | `m_Value`                                                      | text        | 存档位显示文本                       |
| `SimpleTooltip`                                                                          | `infoLeft` / `infoRight`                                       | text        | 悬浮提示左右栏                       |
| `SlotMachineMinigame.SymbolDefinition`                                                   | `displayName`                                                  | name        | 符号显示名                         |
| `SlotMachineMinigame.SlotMachine`                                                        | `betFormat` / `winFormat`                                      | format      | `{0}` 金额格式串                   |
| 自定义类                                                                                     | `_defaultPlayerName` / `_defaultNpc1Name` / `_defaultNpc2Name` | name        | 默认角色/NPC 名                    |
| `CartoonFX.CFXR_ParticleText`                                                            | `text`                                                         | text        | 粒子文字                          |
| `TMPro.TMP_Dropdown`                                                                     | `m_Text`                                                       | text        | 下拉框标签                         |
| `TMPro.TextMeshPro`（3D）                                                                  | `m_text`                                                       | text        | 场景 3D 文本（与 UGUI 版同名小写）        |

提取实现要点（Python 分类器骨架，可复用）：`walk()` 递归收集 `(fieldPath, string)` 时在 `references.RefIds` 特判——只下钻 `RefIds[i].data` 并把路径记为 `RefIds[i].data...`（跳过 `type` 元数据块）；脚本类名不靠 export 文件名，而用 `list_script_types outputFile` 落盘的 (fileId, pathId)→命名空间.类名 映射，从导出 JSON 的 `m_Script` PPtr 反查（失败回退文件名段并计数 `unmapped`）；每条可译 entry 附 `uid` = md5(原文) 前 8 位作去重/回写对齐键。产出单 JSON：`texts`（text/name/format）+ `review_value_strings` + `technical_strings` 三数组，`meta` 记录 per_source_file 统计与 top_script_classes 供汇报规模。

补充实战数据点：格式串可能含数字格式说明符（`Bet: ${0:N0}`）——翻译时整体保留占位符与格式说明符；同一 value 高频重复（同一按钮文本出现 800+ 次）属正常，靠 uid 去重后翻译量大幅下降；多行文本（含 `
`/CRLF）占比虽小（本例 374/25018）但必须走 JSON Lines 并从原 jsonl 精确复制原文（见陷阱表）；TextAnimator 的动画标签名（`size`/`fade`/`wiggle`）落在 `Array` 叶子里，默认拒绝规则可正确归入 tech。


### 3. 导出与提取（本地脚本）

| 步骤               | 操作                                                                                            | 要点                                                                                                                                                                                        |
| ---------------- | --------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1. 批量导出实例        | `export_all file=<文件> typeId=114 scriptIndex=<N> format=json outputDir=<目录> summaryOnly=true` | 文件名规则 `{名称}-{源文件名}-pathid<pathId>.json`，末尾 `pathid<N>` 即定位键，回写 `import_json_batch` 直接可用（**无需另行记录 pathId 映射**）；**summaryOnly=true 只返回统计**，避免实例列表撑爆响应                                       |
| 2. 兜底扫描文本载体      | 全量递归扫描 `references.RefIds[].data` 内英文串（只扫 data，不扫 type/asm 等元数据），按字段名分类                       | `m_Value`/`m_Text` 是可译文本载体；`m_String`（变量名/信号名/类型名）与技术字段（`m_TargetAssemblyTypeName`/`m_MethodName` 等）跳过——能发现目标提取遗漏的载体（如 Dialogue 的 `GetStringString` → `data.m_Value` 物品/称号名），避免只译了对白漏了物品名 |
| 3. 本地提取文本        | 遍历导出 JSON，**只取目标脚本类的文本字段**（字段路径查 **§2c 速查表**），按原文去重                                           |                                                                                                                                                                                           |
| 4. 输出 JSON Lines | 每行一个 JSON 编码字符串                                                                               | **不能用明文行**：多行对白/含换行译文会破坏行对齐                                                                                                                                                               |
| 5. 统计汇报          | 生成 `unique_en.jsonl`（每行一条独特英文文本）；统计 total/cn（中文跳过）/en/sym/empty 分布                            | 向用户汇报                                                                                                                                                                                     |

### 4. 分类（先让用户决策）

提取后做统计分析（重复值、短串、含人名），识别以下类别，**让用户决策是否翻译**：

| 类别             | 识别特征/示例                                                                  | 处理                                                                          |
| -------------- | ------------------------------------------------------------------------ | --------------------------------------------------------------------------- |
| 逻辑/事件标识符       | 变量名（`Cash`/`Lock-Game`）、信号名（`FadeInBlack`）、按钮触发器（`Normal`/`Highlighted`） | **不译**——翻译会破坏游戏逻辑                                                           |
| 测试/占位文本        | `New Text`、`Enter text...`、`uwu`、`gaga`、`test`                           | 保留不译                                                                        |
| 用户名/昵称         | 评论区/聊天室用户名（如 `player123`、`xX_Shadow_Xx`）                                 | 保留英文                                                                        |
| URL/路径/网站/密码掩码 | `www.example.com/...`、`C:/...`、`XXXXX`、`*****`、`0000`                    | 保留英文                                                                        |
| 纯数值/货币/百分比     | `$500K`、`20 Gold`、`60%`、`100 Subscribers`                                | 保留                                                                          |
| 品牌/型号名         | 产品/品牌专名（虚构的相机型号等）                                                        | 保留英文                                                                        |
| 角色名/专名         | 跨文件**复用已有译名表**（此前汉化生成的 `en\tzh` TAB 分隔译名表，UTF-8），新角色名按同样风格音译             | 注意**同名歧义**：同一英文不同上下文含义不同（老虎机符号 `Bar`→"条" vs 场所 `Bar`→"酒吧"），按文件/场景判断，必要时单独覆盖 |
| 占位符/模板         | `{PC}`/`{M}`（运行时替换为角色名）、`{X}` 等花括号模板                                     | 保留原样                                                                        |
| 成人向词条          | 性暗示/成人主题的道具、服装、状态名等                                                      | 询问用户：直译 / 委婉雅化 / 保留英文                                                       |
| 其余对白/描述/UI 标签  |                                                                          | 翻译                                                                          |

> **风格一致性**：游戏若已被部分汉化，先抽查已译内容确立风格（口语化/粗口/游戏术语译法），翻译结果要与之一致（如已译对白里出现的中文标签/术语，其英文原文应按相同措辞翻译）。可用本地 LLM 服务先小批量试译几条向用户确认质量。

### 5. 批量翻译（MCP translate_batch / 直连 HTTP 回退）

| 步骤                    | 操作                                                                                                                                   | 要点                                                                                                                                                                                                 |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1. 调用翻译               | `translate_batch(inputFile=unique_en.jsonl, outputFile=unique_zh.jsonl, from=en, to=zh, gameId=<id>, autoRetryMiss=true)`（完整参数见附录 B） | 内部自动切块（batchSize 默认 10）+ 并发（maxConcurrency 默认 10，**上限 32**）+ 失败重试（maxRetries 默认 2）；**autoRetryMiss=true 自动检测漏译**（译文为空或 trim 后与原文相同）；gameId 必传（服务无配置时可传任意标识串）                                        |
| 1b. MCP 超时 → 直连 HTTP  | MCP 客户端调用约 **30 秒超时**，几千条文本必超；改用 Python 直连服务端（协议 `POST {"texts":[...],"from","to","gameId"}`，ThreadPoolExecutor 50 线程 + 分块 500/块 + 断点续跑），见附录 A9 | 先 curl 探测服务可用；单请求 10 条 ×50 并发实测约 7 分钟/500 条；服务端限速以用户告知为准（如"50 并发即可"→ MCP 上限 32，直连可用 50）                                                               |
| 2. 结构化漏译重试            | 从 en→zh 字典（JSON）取漏译条目（译文为空或 == 原文）**整串**重试一轮（LLM 有随机性，实测可救回 ~88%）                                                                      | **漏译清单必须存 JSON/JSONL，禁止明文行**——多行字符串会被拆断（曾致误判 1073 行）                                                                                                                                             |
| 3. 人工补翻               | 重试后剩余漏译逐条人工翻译（多为**成人内容被服务端过滤**的台词 + 拟声/特殊排版）；保留项（纯符号 '！？'、拟声乱码、按键名、开发占位）映射为自身                                       | 人工译表存独立 py/JSON 文件，便于改稿重跑                                                                                                                              |
| 4. 一致性检查              | 抽查 `{wi}`/`<color>` 等标签是否保留、人名音译是否全程一致（安吉拉/克里斯等）；端点不支持术语表，人名靠 LLM 上下文音译，需抽查                                                             | 标签丢失即打回重翻                                                                                                                                                                                        |

### 6. 回写与验证

| 步骤             | 操作                                                                                                                   | 要点                                                                                                                                                                                                                                                                                                         |
| -------------- | -------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1. 本地映射回写      | 读 `to_translate.jsonl` + `to_translate_zh.jsonl`（含 keep 列表）构建 en→zh 字典，遍历导出 JSON 替换目标字段文本（仅当 `$dict[$t] -ne $t` 才写盘） | **不要用 `ConvertTo-Json`**（PS5.1 解包单元素数组破坏结构）→ Python `json.dump` 或 Newtonsoft；写入字段路径对照 **§2c 速查表**（与提取同一份映射，防漏改）；骨架见附录 A4/A9                                                                                          |
| 1b. **strip 匹配** | 字典 key 通常是 strip 过的池文本，而 JSON 里的原文可能**带前导换行/空格**（Fungus Say.storyText 常见 `'\nDo your best…'`）→ 匹配必须用 `s.strip()` 查字典，否则**静默漏替换** | 实测 92 处替换因此失败且无任何报错——**必须靠步骤 4 的残留审计发现**；修复后需重新 import+save 受影响文件                                                                                                                              |
| 1c. **技术键黑名单** | 单词级键（'speed'/'critical'/'max'/'attack'/'weak' 等）可能经 EventTrigger/Button 的 m_StringArgument 混进字典并被 LLM 译出 → 回写时按黑名单剔除 | 误译写回会**破坏游戏逻辑**（方法参数/状态键）；黑名单在回写脚本里强制过滤一层                                                                                                                                                                                            |
| 2. 替换后验证       | 重扫目标字段（GetStringTextArea/GetStringString/4 个弹出文本字段）                                                                  | 剩余英文应全在 keep 列表（unexpected_miss=0）；抽查译文与游戏已有风格一致                                                                                                                                                                                                                                                           |
| 3. 补漏          | 统计替换后仍未翻译的文本（非中文且不在字典），单独翻译后补替                                                                                       | 多为**多行文本**（换行符 CRLF/LF 差异导致匹配失败）与 strip 差异（见 1b）                                                                                                                                                                                           |
| 4. 批量回写        | `import_json_batch file=<文件> jsonDir=<导出目录> skipUnchanged=true`                                                      | skipUnchanged 与当前数据字节对比，未变更资源跳过、只标记实际变更；success 数应与本地脚本 changedFiles 数一致（分文件合计）；**响应极长会被截断**，以 success/failed 计数为准；save_file 后 MCP 内存即为最新状态，无需重新 open 即可扫描                                                                                             |
| 5. 先测试副本再落真实文件 | 复制真实文件到工作目录（如 `<文件>_tmp_test`）→ `open_file` → import → `save_file` → 重新 `scan_text` 验证中文生效（英文关键词 count=0、中文关键词 >0）   | 大文件尤其必要；确认无误后**先备份真实文件**（`Copy-Item` 到 `.bak`，注意用户可能已删除旧备份需重新确认）→ 对真实文件 import → `save_file`；对比测试副本与真实文件 **MD5 一致**                                                                                                                                                                                        |
| 6. 最终验证（残留分类）  | 重扫全部显示字段，按保留项过滤后逐条过目                                                                                  | 合理保留：纯符号（▶◀×▼—）、按键名（SHIFT/Z）、开发占位（`resource(amount)`、`potionName`、Lorem ipsum、`9999G`/`HP：99.9` 等运行时模板）、剧情性拟声乱码；**除这些外英文残留应为 0**，否则回到步骤 3                                                                                                                    |

### 7. 代码内硬编码文本（Assembly-CSharp.dll 等，dnSpy MCP + dnfile）

assets 提取完成后**必查**的一类遗漏：硬编码在程序集 #US 堆里的 UI 文本（`Funds {0}/{1}G`、`Critical hit!`、`Rarity: Legendary`、`Enter battle!`、技能名等）。这类文本不在任何 .assets 里，assets 回写改不了，必须改 dll 或运行时接管（XUnity.AutoTranslator）。触发特征：游戏明显还有未汉化的界面文字但 assets 里找不到对应原文。

**7a. 定位与提取**

| 步骤 | 工具 | 要点 |
| --- | --- | --- |
| 1. 加载程序集 | dnSpy MCP `open_files`（传 Managed 目录，一次全加载）→ `list_assemblies` 确认 | firstpass 只含引擎内部消息，主文本在 Assembly-CSharp |
| 2. 反查所有者 | `search_string_literals assembly_name query=<片段>`（大小写不敏感子串）返回 type/method/method_token | 用几条代表性文本反查即可锁定所有者类，不必逐条搜 |
| 3. 逐类全量清单 | `list_string_constants assembly_name type_full_name=<类>`（10 条/页，cursor 翻页）；类大时改 `decompile_type`/`decompile_method` 看用法 | 拿到"类.方法 × 字符串"对照，用于甄别显示文本 vs Debug.Log |
| 4. 拼接句确认 | `decompile_method` 看字符串拼接上下文（如 `a + " is " + b + " near capture!"`） | 拼接碎片要**整体设计译文**：碎片分别替换后必须连读通顺，且各自受字节预算约束（见 7b） |
| 5. 全量扫描（可选，最彻底） | Python `pip install dnfile`：解析 TypeDef/MethodDef 表 + 逐方法体 IL 扫 `ldstr`(0x72) → 一次性得到全部 ldstr→(type,method) 映射 | 见附录 A7 骨架；dnfile API 坑见陷阱表 |
| 6. 甄别 | 三类：①显示文本（`.text =`/`string.Format` 赋值）→ 译；②`Debug.Log`/异常消息 → 不译；③**与逻辑共用的键**（枚举 ToString 比较、资源小写键 'wood'、动画/场景名）→ **禁译** | 判定 ③ 的方法：同一字符串出现在 switch/比较方法里（如 `'All'` 同时用于 enchant 稀有度键与分类显示）则禁译，宁可保留英文 |

**7b. 回写：#US 字符串堆原地替换（安全、免改 IL）**

ldstr token 指向 #US 堆的固定偏移，因此把每个堆条目**原地**重写为"压缩长度前缀 + UTF-16LE 数据 + 标志字节 0x00"、剩余字节补 0x00，所有其他 token 偏移不变，运行时无需任何校验。步骤：

1. 解析 PE→CLI→元数据流定位 `#US` 文件偏移（`#~` 流 heap_sizes 判定各索引宽度）。
2. 遍历堆条目建立 offset→(总字节数, 字符串) 映射（#US 去重，同串单一条目）。
3. 对每条 en→zh：新条目总字节数（前缀+2×字符数+1）**必须 ≤ 原条目总字节数**，否则该条改用 dnSpy MCP `patch_method_il`（Cecil 可扩堆）或缩短译文。**短拼接碎片预算极紧**：如 `'!'` 原条目仅 4 字节，只能放 1 个字符——用全角 `'！'`，把其余语义挪进相邻碎片（如 `' captured by '`→`' 被捕获！凶手是'`）。
4. 原地写回 + 补零 → 输出到工作文件 → 用扫描脚本**重新扫描验证**（ldstr 站点数必须与原文件一致、译文在位、0 解码失败）→ 检查 `CLR_STRONGNAMESIGNED`（Unity 程序集通常为 False）→ 备份原 dll（如 `<名>.dll.zh_patch_bak_<日期>`）→ 覆盖部署。
5. **警告 dnSpy 用户**：外部改文件后 dnSpy 内存里还是旧版本，必须重新加载程序集，**切勿在旧状态下 Save Module**（会把补丁覆盖回英文）。

### 8. 全量字符串差集审计（遗漏复查，assets 提取完成后必做一次）

1. 把**所有**导出 JSON（全部 level/sharedassets/resources 的 typeId=114）里的字符串递归收集，与已提取集合（对白/角色名/UI 文本）做差集。
2. 差集按 (类 × 叶子字段名) 分组统计，**从大到小逐组过目**：触发器名/方法名/Tile 名/消息键等技术组直接排除；`m_StringArgument`、`description`、`slotName`、`*Serif` 等可疑组逐条看值甄别。
3. 对每个文件 `list_assets typeId=49` 检查 TextAsset 是否只在已知文件；`export_all` 曾报 failed 的实例用 `get_asset_info` 查明身份（可能只是语音/技术数据）。
4. 未导出过的小文件（level12、sharedassets* 等）也要补导一次确认为空。
5. 最后做 §7 的 dll 硬编码扫描，报告剩余可见文本总量。

## 必须询问用户的决策点

| 决策       | 原因                                                                        |
| -------- | ------------------------------------------------------------------------- |
| 翻译范围     | 仅对白/变量文本，还是含 UI 组件文本（`scopes=component`），或全部 string（不推荐，破坏逻辑）             |
| 执行方式     | 先试点（选 1-2 个实例跑通全流程）再全量，还是直接全量                                             |
| 翻译风格     | 口语化保真（保留粗口/成人向）或温和雅化——内容尺度大时差异明显                                          |
| 分类保留     | 用户名/URL/数值/品牌名/角色名/测试占位 哪些保留、哪些翻译                                         |
| 已汉化游戏的补漏 | 游戏大部分已是中文时，只翻译剩余英文（`[\u4e00-\u9fff]` 跳过中文），向用户确认分类（金额/占位符/测试文本/符号/彩蛋等保留项） |
| 成人内容     | 性暗示/成人主题的词条：直译 / 委婉雅化 / 保留英文                                              |
| 写回方式     | save_file 覆盖源文件不可逆 → 先备份（用户可能删除过旧备份，需确认后新建）                               |
| 未翻译处理    | 重试无效的漏译条：人工翻译 / 保留英文                                                      |

## 已知陷阱（实战踩坑）

| 陷阱                                         | 现象/原因                                                                                                                                                                                 | 对策                                                                                                                                                                                                                               |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| MCP 参数是 camelCase                          | `pathId`/`typeId`/`jsonPath`/`scriptIndex` 不是下划线风格；部分工具参数名不同：`close_file` 用 `name`（非 `file`）、`save_file` 必填 `output`（覆盖源文件时 output=源路径）、`list_script_types` 的 `outputFile` 目录须先存在否则报错 | 按上表传参                                                                                                                                                                                                                            |
| MCP 重启后内存清空                                | scan_text 的 MonoBehaviour 全部 skipped、结果为 0                                                                                                                                            | 重新 `open_file` + `set_mono_generator`（必须设在解析 MonoBehaviour 之前）                                                                                                                                                                   |
| `list_script_types` 响应截断                   | 脚本类型多时                                                                                                                                                                                | 用 `keyword` 参数过滤，或 `outputFile` 落地                                                                                                                                                                                               |
| `scan_text` 一次最多取 limit 条                  | 超出部分不返回                                                                                                                                                                               | 用 `offset` 分页，响应含 `hasMore` 判断                                                                                                                                                                                                   |
| `set_field` 改不了 MRR 数组内字段                  | 点路径无法触达 `references.RefIds[].data` 内部                                                                                                                                                 | 必须 `import_json` / `import_json_batch` 整体 JSON 回写                                                                                                                                                                                |
| `read_tree` 输出截断                           | 单实例输出可达数十 KB                                                                                                                                                                          | 一律 `export_all summaryOnly=true` 导出到磁盘本地处理                                                                                                                                                                                       |
| 明文行格式损坏                                    | 译文含换行导致行数错位                                                                                                                                                                           | `translate_batch` 输入输出**必须 JSON Lines**                                                                                                                                                                                          |
| 多行文本匹配失败                                   | 换行符可能是 CRLF（`\r\n`），人工构造 `\n` 匹配串会失败；特殊引号（`\u2019` 等）                                                                                                                                 | 从原 jsonl 文件提取精确原文，或按索引/文本精确比对                                                                                                                                                                                                    |
| PS5.1 `ConvertTo-Json` 回写损坏                | 解包单元素数组破坏嵌套结构；生成 jsonl 会损坏曾输出 FileSystemProvider 反射内容                                                                                                                                 | 改用 **Newtonsoft.Json.dll**（从游戏 `BepInEx\plugins\...\Newtonsoft.Json.dll` `Add-Type` 加载）：`JObject.Parse` 修改、`ToString()` 写盘                                                                                                       |
| Newtonsoft 赋中文报 "Unexpected character"     | 直接 `$j['field'] = $str` 会走 JToken.Parse 路径                                                                                                                                            | 给 JToken 赋字符串必须 `[Newtonsoft.Json.Linq.JValue]::new($str)` 显式包装                                                                                                                                                                  |
| PS5.1 语言坑                                  | 无 `Join-String`；脚本正文中文注释 GBK 解析崩溃；`ConvertTo-Json` 深层结构截断；`$pid` 是保留变量                                                                                                                | 用 `-join`；脚本正文避免中文（数据放外部 UTF-8 文件或 `[char]0xXXXX`）；`-Depth 100`；换变量名                                                                                                                                                             |
| `translate_config.json` 的 gameId 读不到       | MCP 进程 BaseDirectory 与预期不一致                                                                                                                                                           | **显式传 gameId 参数**；也可从 `BepInEx\config\AutoTranslatorConfig.ini` 的 `[LLMTranslate] GameId=` 读取                                                                                                                                    |
| 本地 LLM 漏译                                  | 译文=原文常见；成人内容可能被稳定过滤                                                                                                                                                                   | `autoRetryMiss=true` 自动重试；直译需人工确认                                                                                                                                                                                                |
| 翻译 JSON 内嵌未转义双引号                           | 解析失败                                                                                                                                                                                  | 用中文引号规避                                                                                                                                                                                                                          |
| 回写定位                                       | 需要知道导出 JSON 对应哪个资源                                                                                                                                                                    | 文件名 `{名称}-{源文件名}-pathid<pathId>.json` 自带 `源文件名-pathId` 定位信息（名称段：有名资源用 m_Name，无名 MonoBehaviour 用 MonoScript 类名如 TextMeshProUGUI），AI 按文件名即可定位、无需 pathId 对照表；`import_json_batch` 只解析末尾 `pathid<N>`，改稿时只保留末尾 `-pathid<N>`、名称段随意改也能回写 |
| 同名文本上下文歧义                                  | 同一英文（如 `Bar`）在不同 assets/场景含义不同，全局 en→zh 映射会串义                                                                                                                                         | 按文件/场景判断并单独覆盖                                                                                                                                                                                                                    |
| Utage sheet 首行是表头                          | `strings[1]=='Command'`，按列索引取对白时表头词（`Text`/`Voice`）混入文本                                                                                                                               | 跳过表头行；文本列索引从表头读、别写死（详见 §2b）                                                                                                                                                                                                      |
| Utage 命令参数列技术值居多                           | BG 名/角色名/`None`/`0` 混在参数里                                                                                                                                                             | `SendMessageByName` 等命令的参数含义由游戏自定义，**逐条甄别**：可读短语可能是显示文本（如成就名），单词/数字多为技术值；对白里 `<param=xxx>` 占位符保留                                                                                                                                 |
| Utage TMP 包装类自身无文本                         | 对着 `AdvUguiMessageWindowTMP`/`TextMeshProNovelText` 等找不到字段                                                                                                                            | 导出 `TMPro.TextMeshProUGUI` + `UnityEngine.UI.Text` 即覆盖                                                                                                                                                                           |
| `resources.assets` 混有 Unity 内置调试 UI prefab | `DebugUIHandler*` 脚本、文本 `New Text`/`wibble`/`TEST`，scan_text 会命中但非游戏文本                                                                                                                | 统计与翻译都应排除                                                                                                                                                                                                                        |
| 语言模式影响"已译"判断                               | Utage 的 LanguageManager 可设日文模式但对白只有英文一份（或反之）                                                                                                                                          | 中/英/日分布按载体分开统计，别用单一 `[\u4e00-\u9fff]` 规则套全部文件                                                                                                                                                                                    |
| 脚本映射文件名不一致                              | `list_script_types outputFile` 落盘名与源文件名不一一对应（如 `resources.assets`→`resources.assets.json`，而 `level0`→`level0.json`、`sharedassets1.assets`→`sharedassets1.json`） | 本地建 m_Script→类名映射时按 `{src}.json` 和 `{src}.assets.json` 两个候选依次找；只试一个会把整个文件的字符串全判成 `?` 类而漏提取（曾致 137 条 UI Text 全漏）                                                                  |
| walk 生成路径带前导点                           | 递归 walk(dict) 用 `path+'.'+k`，顶层字段路径是 `.nameText` 而非 `nameText`                                                              | 分类匹配用 `path.split('.')[-1]` 取叶子，或 strip 前导点；直接 `field=='nameText'` 全等比较会 0 命中                                                                                                |
| Fungus 命令不是 Flowchart 子对象               | 只导出 Flowchart 实例（几十字节）找不到对白                                                                                             | Say/Conversation/Block 等命令是同文件独立 MonoBehaviour，按类名全量导出                                                                                                                        |
| `m_StringArgument` 用途随类/场景漂移             | EventTrigger 的可能是设施悬停说明（显示文本），Button/Slider 的多为方法参数键，level 间用途也不同                                                        | 按非空值逐条甄别：含空格可读句 → text；单词/蛇形键 → tech                                                                                                                                         |
| 枚举/逻辑共用串误译破坏游戏逻辑                        | `'All'`/`'Sword'`/`'Top'` 等既显示又参与 ToString 比较（enchant 稀有度键、装备槽位）                                                        | 凡出现在比较/switch 方法里的字符串一律禁译；显示与逻辑分离的（如小写键 vs 大写显示名）只译显示那份                                                                                                                       |
| dnfile API 三个坑                          | `pe.get_data_at_rva` 不存在（用 `pe.get_offset_from_rva` 后切 `pe.__data__`）；`UserStringHeap.get` 要传 **token 低 24 位**（`tok & 0xFFFFFF`），传全 token 报 "stream is too small"；`TypeNamespace` 是 HeapItemString（用 `str()` 或 `or ''` 处理，不能直接拼） | 按左处理即可                                                                                                                                                                       |
| IL 手写解码对不齐                              | ldstr 站点漏报/误报                                                                                                           | 需要完整 opcode 长度表：FE 前缀（FE06/07/15/16/18/19/1B 记 +4，FE09-0E 记 +2，FE12 记 +1）、switch(0x45)=5+4n、0x2B-37=2、0x38-44=5；遇未知 opcode 直接 raise 而不是默认 +1                                          |
| #US 原地替换溢出                              | 译文（前缀+UTF16+标志）超过原条目字节数会踩坏下一入口                                                                                          | 每条校验 `new_total <= old_total`；短碎片（`'!'` 仅 4 字节）预算极紧——用全角字符（1 字符）并把语义挪进相邻碎片；超限条目改用 dnSpy MCP patch_method_il（Cecil 扩堆，任意长度）                                                     |
| 外部改 dll 后 dnSpy 内存过期                    | dnSpy 里 Save Module 会把旧内存内容整写回，外部补丁被覆盖回英文                                                                               | 外部回写后要求用户重新加载程序集；或全部回写走 dnSpy MCP（patch_method_il + save_assembly），不要混用两条写路径                                                                                                  |
| resources.assets 全是字体/引擎资源              | 扫到 TMP_FontAsset/StyleSheet/Emoji 噪声误导统计                                                                                | 以"该文件的脚本类型表含哪些游戏文本类"为准判断有无文本，别按文件大小猜                                                                                                                                         |
| translate_batch MCP 30 秒超时              | 几千条文本的批量翻译必然超时，且 MCP 并发上限 32                                                                                            | 改 Python 直连 HTTP（协议 `POST {"texts":[...],"from","to","gameId"}`）+ ThreadPoolExecutor 50 线程 + 分块断点续跑；漏译重试一轮能救回大部分（LLM 随机性）                                                     |
| 成人内容被翻译服务过滤                             | LLM 对露骨台词稳定返回原文（漏译），成人游戏漏译率可达 15%                                                                                       | 重试（随机性）→ 仍漏的人工补翻；漏译清单必须存 JSON，明文行会因多行字符串拆断而错乱                                                                                                                                |
| 池 key strip 与原文不一致 → 静默漏替换              | 池 key 是 strip 后的，JSON 原文带前导 `\n`/空格（Fungus Say 常见），`s in dict` 精确匹配失败且**无任何报错**                                          | 回写匹配用 `s.strip()` 查字典；替换条件 `newv != key`（比 strip 后的 key）；**每次回写后必跑残留审计**——实测 92 处因此漏替换全靠审计抓回                                                                     |
| 单词技术键混进翻译字典                             | EventTrigger/Button 的 m_StringArgument（'speed'/'critical'/'weak' 等）作为"非空字符串"进了池，LLM 译成中文后回写会**破坏游戏逻辑**                    | 池构建时按来源甄别；回写字典强制过技术键黑名单（speed/critical/max/attack/weak/normal/strong/cheat/delete/装备部位键等）                                                                                     |
| TextAsset 用 export_all txt 导出乱码/解析失败     | dump 的转义串二次解码把非 ASCII 弄成 `ã€【` 类乱码，JSON 也解析失败                                                                           | 改用 `export_text_asset_text`（逐 pathId，干净 UTF-8）；游戏 JSON 尾逗号用 `re.sub(r',\s*([}\]])', r'\1', s)` 容忍解析                                                                          |
| 键表与显示名表混淆                               | playLabelName（值是 `_1_3start` 场景键）与 playSceneName（值是显示名）名字相近；tirasi 实为日语开发备忘录                                            | **抽查值内容定性质**再决定翻译范围；顶层数字键 dict（"0"/"1"）的 leaf 判断别写成数字而漏收（表现为某表译文字符数为 0）                                                                                                       |
| 模板占位文本误判为漏翻                             | UI 里的 `Lumber: 99 (99)`、`Enemies Defeated: 999`、`HP：99.9` 是运行时格式化模板，`resource(amount)`/`potionName` 是隐藏开发名               | 归入保留项；翻译它们无害但非必需，终验时不算残留                                                                                                                                                     |

## 附录 A：核心脚本骨架（PowerShell 5.1，无中文注释）

以下脚本用 .NET API 读写文件，规避 PowerShell 编码/序列化陷阱。**中文字面量不能写进 .ps1 源码**（GBK 解析崩溃），统一放外部 UTF-8 数据文件或用 `[char]0xXXXX` 构造。

### A1. 提取独特英文文本 → jsonl（按目标字段过滤）

```powershell
# 参数
$dir = '<导出目录>'            # export_all 的输出目录
$outJsonl = '<工作目录>\unique_en.jsonl'
# 目标类与字段路径查 §2c 脚本类文本结构速查（如 Dialogue->data.m_Text.m_Text、TextMeshProUGUI->m_text）
# 按目标类替换下方 m_Script.m_PathID 过滤值与字段名

function Escape-Json([string]$s) {
  return $s.Replace('\','\\').Replace('"','\"').Replace("`r",'\r').Replace("`n",'\n').Replace("`t",'\t')
}

$seen = New-Object 'System.Collections.Generic.HashSet[string]'
$list = New-Object System.Collections.Generic.List[string]
foreach ($f in Get-ChildItem $dir -Filter '*.json') {
  $j = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($null -eq $j.m_Script) { continue }
  if ([string]$j.m_Script.m_PathID -ne '5917') { continue }      # 按目标脚本 pathId 改（TextMeshProUGUI=5917 为例）
  $t = [string]$j.m_text                                         # 按目标字段改（m_text / m_Text / _text / m_Value...）
  if ([string]::IsNullOrWhiteSpace($t)) { continue }
  if ($t -match '[\u4e00-\u9fff]') { continue }                 # 跳过已中文
  if ($t.Trim().Length -le 1) { continue }
  if ($seen.Add($t)) { $list.Add('"' + (Escape-Json $t) + '"') }
}
[IO.File]::WriteAllLines($outJsonl, $list, (New-Object System.Text.UTF8Encoding($false)))
"UNIQUE=$($list.Count)"
```

### A2. 分类筛选（保留清单 + 角色名译名表）

```powershell
# keep 数组内嵌用户名/URL/数值/占位符（ASCII，逐条列出或用正则）
$keep = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($k in @('player123','www.example.com/path','New Text','Enter text...')) { [void]$keep.Add($k) }
# 数值/货币正则：$500K、20 Gold、60%、100 Subscribers、时间戳等
$keepPat = '^\$[\d.,]+K?$|^\+?\$[\d.,]+$|^[\d.,%]+$|^[\d.,]+ ?(Gold|Subscribers|Coins|Fans?|followers?)$|^[\d:/.]+$|^\d+\.$'

# 角色名译名表（复用跨文件已有译名表，TAB 分隔 en\tzh，UTF-8）
$names = @{}
foreach ($line in [IO.File]::ReadAllLines('<译名表>.txt', [Text.Encoding]::UTF8)) {
  $p = $line -split "`t"
  if ($p.Count -ge 2) { $names[$p[0]] = $p[1] }
}

# 遍历 unique_en.jsonl：命中 keep 保留、命中 names 用译名、其余进 to_translate.jsonl + idx.txt
```

### A3. 合并译文回全集（按索引覆盖）

```powershell
$enLines = [IO.File]::ReadAllLines('unique_en.jsonl', [Text.Encoding]::UTF8)
$idxLines = [IO.File]::ReadAllLines('idx.txt', [Text.Encoding]::UTF8)
$trZh = [IO.File]::ReadAllLines('to_translate_zh_fixed.jsonl', [Text.Encoding]::UTF8)
$out = New-Object 'System.Collections.Generic.List[string]'
for ($i = 0; $i -lt $enLines.Count; $i++) { $out.Add($enLines[$i]) }
for ($i = 0; $i -lt $idxLines.Count; $i++) { $out[[int]$idxLines[$i]] = $trZh[$i] }
# names 表按 en 匹配覆盖对应索引
# keep 条目保持原样
[IO.File]::WriteAllLines('unique_zh.jsonl', $out, (New-Object System.Text.UTF8Encoding($false)))
```

### A4. 映射回写（en→zh 字典替换目标字段，Newtonsoft.Json）

**必须用 Newtonsoft.Json 而非 ConvertTo-Json**（PS5.1 解包单元素数组会破坏嵌套结构）。给 JToken 赋字符串要 `[JValue]::new(...)` 显式包装。字典只含 to_translate 条目，keep 条目 map 到自身（不写盘）。

```powershell
Add-Type -Path 'G:\...\BepInEx\plugins\XUnity.AutoTranslator\Translators\FullNET\Newtonsoft.Json.dll'
$tmp = '<工作目录>'
$utf8 = New-Object System.Text.UTF8Encoding($false)
# en -> zh 字典（to_translate.jsonl 与 to_translate_zh.jsonl 行号一一对应）
$trEn = [IO.File]::ReadAllLines("$tmp\to_translate.jsonl", [Text.Encoding]::UTF8)
$trZh = [IO.File]::ReadAllLines("$tmp\to_translate_zh.jsonl", [Text.Encoding]::UTF8)
$dict = @{}
for ($i = 0; $i -lt $trEn.Count; $i++) {
  $dict[[string](($trEn[$i] | ConvertFrom-Json))] = [string](($trZh[$i] | ConvertFrom-Json))
}
# keep 条目（保留清单）map 到自身 → 不会写盘
foreach ($l in [IO.File]::ReadAllLines("$tmp\keep.jsonl", [Text.Encoding]::UTF8)) {
  $k = [string](($l | ConvertFrom-Json)); if (-not $dict.ContainsKey($k)) { $dict[$k] = $k }
}

$hit = 0; $files = 0
# Dialogue：GetStringTextArea -> data.m_Text.m_Text；GetStringString -> data.m_Value
foreach ($f in Get-ChildItem "$tmp\export_dialogue" -Filter '*.json') {
  $jo = [Newtonsoft.Json.Linq.JObject]::Parse([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8))
  $changed = $false
  foreach ($ref in $jo['references']['RefIds']) {
    if ($ref['type'] -eq $null -or $ref['data'] -eq $null) { continue }
    $cls = [string]$ref['type']['class']
    if ($cls -eq 'GetStringTextArea') {
      $t = [string]$ref['data']['m_Text']['m_Text']
      if ($dict.ContainsKey($t) -and $dict[$t] -ne $t) {
        $ref['data']['m_Text']['m_Text'] = [Newtonsoft.Json.Linq.JValue]::new([string]$dict[$t])  # 必须 JValue::new！
        $changed = $true; $hit++
      }
    } elseif ($cls -eq 'GetStringString') {
      $t = [string]$ref['data']['m_Value']
      if ($dict.ContainsKey($t) -and $dict[$t] -ne $t) {
        $ref['data']['m_Value'] = [Newtonsoft.Json.Linq.JValue]::new([string]$dict[$t])
        $changed = $true; $hit++
      }
    }
  }
  if ($changed) { [IO.File]::WriteAllText($f.FullName, $jo.ToString(), $utf8); $files++ }  # 无 BOM，仅变更才写盘
}
# DamageNumberGUI：topText/bottomText/leftText/rightText
foreach ($f in Get-ChildItem "$tmp\export_damage" -Filter '*.json') {
  $jo = [Newtonsoft.Json.Linq.JObject]::Parse([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8))
  $changed = $false
  foreach ($fn in @('topText','bottomText','leftText','rightText')) {
    $t = [string]$jo[$fn]
    if ($dict.ContainsKey($t) -and $dict[$t] -ne $t) {
      $jo[$fn] = [Newtonsoft.Json.Linq.JValue]::new([string]$dict[$t]); $changed = $true; $hit++
    }
  }
  if ($changed) { [IO.File]::WriteAllText($f.FullName, $jo.ToString(), $utf8); $files++ }
}
"HIT=$hit FILES=$files"
# 替换后重扫目标字段验证（附录 A6 思路）：剩余英文应全在 keep 列表（unexpected_miss=0）
```

### A5. 人工修复漏译（en→zh 覆盖，JSON Lines 数据文件）

漏译条目（`missTexts`）需要人工翻译时，把目标原文与译文做成两个 JSON Lines 文件（目标原文从 unique_en.jsonl 原样复制保证精确，含换行/CRLF/特殊引号；译文用 `\uXXXX` 转义或 Escape-Json），按索引匹配覆盖：

```powershell
# targets.jsonl（原文，从 jsonl 原样复制） 与 fix_zh.jsonl（译文，JSON 编码）行号一一对应
# 脚本：遍历 en jsonl，若命中 targets[j] 则 zh[i] = fixZh[j]
# 注意多行文本换行符 CRLF/LF 必须与原文完全一致（从原 jsonl 复制而非手敲）
```

### A6. 递归扫描 `references.RefIds[].data` 发现全部文本载体（避免漏译）

只扫 `data`（不扫 type/asm/rid 等元数据），按字段名区分可译（`m_Value`/`m_Text`）与技术（`m_String`/`m_TargetAssemblyTypeName`/`m_MethodName`）。**Dialogue 的 `GetStringString` → `data.m_Value` 常被目标提取漏掉**（物品/称号名、商店对白），此扫描可兜底。

```powershell
function Walk-Data($obj, [string]$path) {
  if ($obj -is [System.Management.Automation.PSCustomObject]) {
    foreach ($p in $obj.PSObject.Properties) { Walk-Data $p.Value ($path + '.' + $p.Name) }
  } elseif ($obj -is [System.Collections.IEnumerable] -and -not ($obj -is [string])) {
    $i = 0; foreach ($item in $obj) { Walk-Data $item ($path + '[' + $i + ']'); $i++ }
  } elseif ($obj -is [string]) {
    $t = [string]$obj
    if ($t -match '[A-Za-z]' -and -not ($t -match '[\u4e00-\u9fff]')) { $script:lines.Add("$path = $t") }
  }
}
$lines = New-Object System.Collections.Generic.List[string]
foreach ($f in Get-ChildItem '<导出目录>' -Filter '*.json') {
  $j = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($null -eq $j.references) { continue }
  foreach ($ref in $j.references.RefIds) {
    if ($null -eq $ref.type -or $null -eq $ref.data) { continue }
    Walk-Data $ref.data ($f.BaseName + ' [class=' + [string]$ref.type.class + '] data')  # 带上 class 便于归类
  }
}
[IO.File]::WriteAllLines('<输出>.txt', $lines, (New-Object System.Text.UTF8Encoding($false)))
# 之后按路径末字段分组统计：m_String 是技术字段（变量/信号名），m_Value/m_Text 才是可译文本

### A7. 程序集 ldstr 全量扫描（Python + dnfile，§7 硬编码文本定位）

一次性输出 "类\t方法\tIL偏移\t字符串" TSV，覆盖全部方法体（无需逐个 MCP 搜索）：

```python
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
```

### A8. #US 堆原地替换回写（§7b 硬编码文本汉化）

```python
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
```

```

### A9. 直连 HTTP 批量翻译 + strip 匹配回写（Python，§5/§6 的 Fungus 数据驱动游戏全流程）

```python
# ① 直连翻译（MCP translate_batch 超时时的回退；并发数以用户告知为准）
import json, urllib.request, threading, queue, time
ENDPOINT = 'http://127.0.0.1:51821/api/translate'
def call(texts, game='wifesurviver'):   # gameId 无配置时传任意标识串
    req = urllib.request.Request(ENDPOINT,
        data=json.dumps({'texts': texts, 'from': 'en', 'to': 'zh', 'gameId': game}).encode(),
        headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=180) as r:
        return json.loads(r.read())['translations']
# 分块 500 行/文件 → 线程池(50) 内每请求 10 条 → 写 zh_XX.jsonl（断点续跑：已有行跳过）

# ② 结构化漏译重试（en->zh 为 JSON，切勿明文行）
d = json.load(open('en_zh.json', encoding='utf-8'))
misses = [k for k, v in d.items() if (not v) or v.strip() == k.strip()]
# 分批(4条)并发重试 → d[k]=t 仅当 t 非空且 t.strip()!=k.strip() → 写回 en_zh.json
# 剩余漏译人工补翻（manual_fix.py 独立译表），保留项映射为自身

# ③ MonoBehaviour 回写（strip 匹配 + 技术键黑名单）
d = json.load(open('en_zh.json', encoding='utf-8'))
d = {k: v for k, v in d.items() if v and v.strip() and v.strip() != k.strip()}
TECH_KEYS = {'speed','critical','max','attack','weak','normal','strong','cheat','delete',
             'tough','dexterity','power','evation','luck','hp','wood','iron','stone','cloth',
             'leather','magi','soul','fera','manko','chikubi','anal'}
d = {k: v for k, v in d.items() if k not in TECH_KEYS}
LEAVES = {'storyText','stringVal','nameText','m_Text','m_text','description',
          'm_StringArgument','slotName','defaultSerif','equippedSerif','exchangeSerif',
          'lockedSerif','info','infoLeft','infoRight'}
def walk(o, path=''):   # 递归产出 (路径, 值)；dict 键拼 path+'.'+k（注意顶层带前导点）
    if isinstance(o, dict):
        for k, v in o.items(): yield from walk(v, path + '.' + k)
    elif isinstance(o, list):
        for i, v in enumerate(o): yield from walk(v, '%s[%d]' % (path, i))
    else: yield path, o
for fn in os.listdir(export_dir):
    j = json.load(open(fn, encoding='utf-8'))
    for path, s in walk(j):
        if path.split('.')[-1] not in LEAVES or not isinstance(s, str): continue
        key = s.strip()                       # ★ strip 匹配：原文常带前导 \n
        newv = d.get(key)                     # Conversation 前缀拼装在此之外单独处理
        if newv and newv != key:
            # 按路径回写（re.findall 解析 .key / [idx] token）后 json.dump 写盘
            ...
    # 仅变更才写 → MCP: import_json_batch(skipUnchanged=true) → save_file(output=源路径)

# ④ 残留审计（每轮回写后必跑；排除符号/技术键/开发占位/纯数值后英文应为 0）
#    SYM=re.compile(r'^[\W_]*$')；另排除 'HP：99.9' 类运行时模板与 Lorem ipsum
```

## 附录 B：translate_batch 调用（MCP）

```
translate_batch(
  inputFile=  <工作目录>\to_translate.jsonl,
  outputFile= <工作目录>\to_translate_zh.jsonl,
  from=en, to=zh,
  endpoint=   http://127.0.0.1:51821/api/translate,
  gameId=     <XUnity.AutoTranslator 配置中的 GameId>,
  batchSize=10, maxConcurrency=10, maxRetries=2,
  autoRetryMiss=true)          # 自动漏译重试，返回 missTexts/missAfterRetry
```

## 附录 C：旧流程（MCP 未升级时的回退方案）

无 `translate_batch` / `import_json_batch` 时：

- 翻译：人工逐条翻译（或本地脚本直接 HTTP 调翻译服务，自行实现切块/并发/重试与 JSON Lines 输出）
- 回写：逐个 `import_json(file=<文件>, pathId=<pathId>, jsonPath=<修改后JSON>)` 分批完成（百个实例约十余批），再 `save_file`
- 提取/映射脚本同上（A1/A4）

## 说明

本 skill 只描述可复用的工作流。不要在其中写入具体游戏的 pathId、昵称、译文等任务数据——每次执行时按流程现场提取。游戏名、翻译风格、是否含成人内容等需在执行中询问用户。
