# 引擎专项：Utage（视觉小说）与 Fungus

两引擎通用的定位套路：`list_script_types` 查 scriptIndex → `list_assets typeId=114 scriptIndex=<N>` 枚举实例。字段分类与回写规则见 class-fields.md。

**触发特征**：

- **Utage**：`list_script_types` 出现大量 `Utage.*` 类（`AdvEngine`、`AdvScenarioPlayer`、`AdvUguiMessageWindowTMP`、`TextMeshProNovelText` 等）。
- **Fungus**：Managed 目录有 `Fungus.dll`；类型表出现 `Flowchart`、`Say`、`Character`、`Conversation`、`Block`、`SayDialog`、`MenuDialog`、`MessageReceived`、`Stage`、`View`、`Writer`、`Localization`。

## Utage

### 载体与数据链

| 载体 | 定位特征 | 字段/文本位置 | 处理规则 |
| --- | --- | --- | --- |
| `Utage.AdvImportScenarios` | 实例体积小（几十字节） | `chapters` → PPtr 引用 `AdvChapterData` | 仅引用无文本，顺链下钻 |
| `Utage.AdvChapterData` | 实例几 KB | `chapterName`；`settingList.Array[].rows[].strings.Array`（各 Setting 表）；`dataList` → PPtr 引用 `AdvImportBook` | Param 表的 `saveTitle` 等字符串值可译；经 `dataList` 定位剧本主体 |
| `Utage.AdvImportBook`（"xxx.book"，**剧本主体**） | 实例体积 MB 级，看 size 即识别（不必 read_tree）；IL2CPP 版常**无 StreamingAssets**，内嵌 sharedassets | `importGridList.Array[]` 每个 sheet 一个场景 label（`name` 形如 `Assets/.../xxx.xls:<label>`）；行 = `rows.Array[].strings.Array`（TSV 网格） | 行级提取规则见下表 |
| `Utage.LanguageManager` | 实例小 | `language`/`defaultLanguage`/`dataLanguage`（语言状态）；`languageData` → PPtr 引用 TextAsset 本地化表 | 语言状态是"已译/未译"判断基准；**对白与 UI 语言可能不一致**（如对白仅英文一份、UI 日英双语），分布按载体分开统计，别用单一 `[\u4e00-\u9fff]` 规则套全部文件 |
| 本地化 TextAsset 表 | `list_assets typeId=49` 枚举 → `export_all typeId=49` 导出 | `m_Script` 文本 = `Key\t<语言1>\t<语言2>` TSV（常带 UTF-8 BOM） | 按 Key 解析各语言列；`UguiLocalize.key` 对应 Key 列 |
| `Utage.UguiLocalize` | 场景内大量实例 | `key` 字段 | 本地化键，**技术值不译**，可作 UI 文本归属参考 |
| Utage TMP 包装类（`AdvUguiMessageWindowTMP` / `TextMeshProNovelText` / `TextMeshProRuby` / `AdvUguiSelectionTMP` / `AdvUguiBacklogTMP` 等） | — | 自身**无序列化文本**，只引用 TMP 组件（`UguiIndexTextTMP` 仅 `formatIndexText` 模板） | 直接导出 `TMPro.TextMeshProUGUI` + `UnityEngine.UI.Text` 覆盖其显示文本 |

### AdvImportBook 行级提取规则

| 行类型 | 识别方式 | 提取规则 |
| --- | --- | --- |
| 表头行 | `strings[1]=='Command'` | **必须跳过**，否则表头词（`Text`/`Voice`）混入文本 |
| 对白行 | `strings[1]` 为空 且 文本列非空 | 文本列索引**从表头行读取、不要写死**（典型 `['', 'Command','Arg1'..'Arg6','WaitType','Text','PageCtrl','Voice','WindowType']` → Text 列 = 9） |
| 命令参数显示文本 | `strings[1]=='SendMessageByName'` 等命令的参数列（SendMessageByName = 向指定名称组件发送字符串参数，用途由游戏自定义） | 参数可能是显示文本（有游戏用作成就名）也可能是技术值（BG 名/角色名/`None`/`0`）——**逐条甄别，勿套用单一正则**：含空格的可读短语优先人工确认，单词/数字多为技术值 |
| 占位符 | 对白文本中 `<param=xxx>` | 运行时替换角色名/参数，翻译需保留 |

## Fungus

**注意：Fungus 命令对象（Say/Menu 等）不是 Flowchart 的子对象，而是与 Flowchart 同文件的独立 MonoBehaviour**，由 Flowchart 的 commandList PPtr 引用——只导出 Flowchart 实例（几十字节）找不到对白，按类名全量导出。

### 载体与数据链

| 载体 | 定位特征 | 字段/文本位置 | 处理规则 |
| --- | --- | --- | --- |
| `Fungus.Say` | 每条对白一个实例（几百字节），主场景可达数千 | `storyText`（对白主体）；`character` PPtr → `Fungus.Character`；`description`（编辑器备注，一般不译） | 主对白库；按 `itemId` 可排序还原剧情顺序 |
| `Fungus.Character` | 场景内几十个 | `nameText`（说话人显示名） | 角色名；`character` PPtr 的 m_PathID 反查 nameText 得到每条对白的说话人 |
| `Fungus.Conversation` | 少量 | `conversationText.stringVal` | 整串需拆分，见下 |
| `Fungus.Block` | 每个 Block 一个 | `blockName`（**技术值不译**）；`description`（常存章节/剧情标题，如 "A Night of Secrets"） | description 是编辑器元数据，**是否在游戏内显示需实测**（可能用于章节选择/存档标签），先提取为 review 类 |
| `Fungus.MessageReceived` | — | `message`（Fungus 消息事件键） | **技术值不译** |
| `Fungus.Localization` | 实例极小（几十字节）= 空表 | `stringTable` | 空表说明无多语言数据，全文本为单一语言 |
| `SayDialog`/`MenuDialog`/`Writer`/`Stage`/`View` | UI 外壳 | 自身无对白文本（`UguiIndexTextTMP` 仅 formatIndexText 模板） | 导出 `Text`/`TextMeshProUGUI` 覆盖其显示文本 |

**Conversation 的 `conversationText.stringVal` 格式**实为 **"角色名 [姿势] [Part]:文本"**（Part ∈ Unknown/Middle/Bottom 等，如 `Angela 0_half L1:Ngh...`、`UNKNOWN Hide:`），**不要假设一定有 Part 关键字**——拆分点就是**第一个冒号**，前缀保留原样、只译冒号后的文本段，回写时重新拼装。

### Fungus 游戏特有的其他文本载体（依脚本类 × 字段甄别）

| 类 × 字段 | 类别 | 说明 |
| --- | --- | --- |
| `EventTrigger.m_StringArgument` | **review→text** | 可能是设施/属性悬停说明等显示文本，也可能是技术键（如 'speed'/'critical'）——**逐条按可读性甄别**，同一字段在不同 level 用途不同 |
| `Button`/`Slider.m_StringArgument` | tech | 方法参数键（状态 id、动画键等），不译 |
| 自定义 `*Manager` 类的 `*Serif` 字段（defaultSerif/equippedSerif/exchangeSerif/lockedSerif 等） | text | NPC 台词，序列化在场景实例里（.ctor 里的默认值会被场景值覆盖）；同类还有 `slotName`（EquipSlot 装备槽名）等 |
| `ItemButton`/`EquipManager` 等的 `statsToStr` 映射 | tech | 'hp'/'power' 等小写键为**逻辑比较键**；对应显示串（'HP'/'ATK' 等）若是独立 ldstr 才可译 |
| **枚举/比较共用串**（`'All'`、`'Sword'`、`'Top'`、`'Weapon'`、`'Normal'` 等） | **tech 禁译** | 同一字符串既显示又参与 `ToString()==` 比较（如 enchant 稀有度键、装备槽比较）——凡该串出现在 switch/比较逻辑的方法里，一律不译 |
| TextAsset JSON 数据表（typeId=49） | text/name | Fungus+Lua 或数据驱动游戏常把物品/敌人/技能/通知/地名放 `resources.assets` 的 TextAsset（如 ItemData/enemyData/enchantData/facilityData/notificationData/castSerif），按 JSON 键名甄别 name/description/label 字段；`FungusTypes`/`UnityTypes`/LineBreaking 等为引擎表不译 |

### TextAsset 数据表处理规则（实战踩坑汇总）

1. **导出必须用 `export_text_asset_text`（逐 pathId）**，旧版服务端不要用 `export_all format=txt` 的 dump——dump 里的转义串二次解码会把非 ASCII 弄成乱码（`ã€【`），且对含转义的 JSON 会解析失败（v1.4 已修复：txt 格式下 TextAsset 直接写干净 UTF-8 全文）。
2. **游戏 JSON 常带尾逗号**（Newtonsoft 容忍、Python 不容忍）→ 解析前 `re.sub(r',\s*([}\]])', r'\1', s)`；含 `\"` 与字面 `\r\n` 转义属正常。
3. **先看内容再定性质**：同名 ".json" 可能是开发备忘录（如 tirasi 是日语设计笔记，排除）、场景键表（playLabelName/scenarioLabelName 的值是 `_1_3start` 类键，排除）或显示名表（playSceneName/scenarioSceneName 是 "Muscleman vs. Swordswoman" 类显示名，要译）——**键表与显示名表名字只差一个词，必须抽查值**。顶层以数字为键的 dict（playSceneName 的 "0"/"1"）提取时别把 leaf 判成数字键而漏收。
4. **只收显示键**（itemName/name/description/label/names/effectDescription），effect/playType/moveType 等键是逻辑值；notificationData 整表都是对白行可直接全收。

### Fungus 定位流程

`list_script_types` 落盘全部文件 → 找含 `Say`/`Flowchart` 的 level → `export_all typeId=114` 全量导出该 level 的 MonoBehaviour → 本地按 m_Script pathId 映射类名、walk 全字段 → Say.storyText + Character.nameText + Conversation.stringVal + UI 组件文本 + TextAsset 表 → 去重成 unique jsonl。
