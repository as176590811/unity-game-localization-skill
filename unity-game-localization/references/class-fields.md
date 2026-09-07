# 脚本类→文本字段字典与分类法

提取、分类、回写三处都要对照本文件。每条文本用**四元组 `file + pathId + scriptClass + fieldPath`** 定位：`file+pathId` 即 export_all 文件名末尾的 `-源文件名-pathid<N>`，`fieldPath` 是导出 JSON 内的完整字段路径，回写按同一路径替换。每个 string 按下文分类为 `text`（可译）/ `name`（名称类，译名需一致）/ `format`（格式串，保留 `{0}` 占位符）/ `review`（混合，人工甄别）/ `tech`（技术值，禁止写回）。Utage/Fungus 引擎专属载体见 engines.md。

通用判断：文本字段是 `type.class` 明确的字符串载体（`GetStringTextArea` / `ValueString`）或 UI 组件 text 字段（`m_text`/`m_Text`/`_text`），技术字段（变量名/信号名/触发器/资源名）一律跳过。

## 脚本类文本结构速查

| 脚本类 | 文本位置 | 说明 |
| --- | --- | --- |
| `GameCreator.Runtime.Dialogue.Dialogue` | `references.RefIds[]` 中 `type.class=="GetStringTextArea"` 的 `data.m_Text.m_Text`（对白主体）；`type.class=="GetStringString"` 的 `data.m_Value`（物品/称号/标签名、商店对白等） | 对白 + 物品/称号名 |
| `DamageNumbersPro.DamageNumberGUI` | 顶层字段 `topText`/`bottomText`/`leftText`/`rightText`（受 enableTopText 等开关控制）；`number`、`digitSettings.suffixes`（K/M/B/T）为数值格式**不译** | 伤害/粉丝/订阅弹出文本 |
| `GameCreator.Runtime.Variables.LocalListVariables` / `LocalNameVariables` | `type.class=="ValueString"` 的 `data.m_Value`（字符串） | 变量表文本 |
| `TMPro.TextMeshProUGUI`（UI 文本） | `m_text`（小写） | 按钮/标签/聊天/邮件/教程文本 |
| `TMPro.TextMeshPro`（3D 文本） | `m_text`（小写） | 场景内 3D 文本 |
| `UnityEngine.UI.Text` | `m_Text`（大写） | 旧版 UI 文本 |
| `Febucci.TextAnimator_TMP` | `_text` | 打字机动画文本 |
| `TMPro.TMP_Dropdown` | `m_Text` / `m_Options.m_Options.Array[i].m_Text` | 下拉框标签 / 下拉选项（选项在嵌套 Array 内，叶子仍为 m_Text） |
| `GameCreator.Runtime.Common.UnityUI.ButtonInstructions` | `references.ref[N].m_Value`（如 `Click!`） | UI 交互文本，可译 |
| `CartoonFX.CFXR_ParticleText` | `text` | 粒子文字 |
| 各类脚本 | `m_Variable.m_Name.m_String`（变量名）、`m_Signal.m_String`（信号名）、`m_TypeID.m_String`（number/boolean） | **技术字符串，不译** |

## 字段定位分类法（按"叶子字段名 × 脚本类"，优先级从上到下）

| 优先级 | 规则 | 类别 | 说明 |
| --- | --- | --- | --- |
| 1 | `fieldPath` 末段命中 `.m_Variable.m_Name.m_String` / `.m_Variable.m_TypeID.m_String` / `.m_Signal.m_String` | tech | 变量名/类型名/信号名；GameCreator 资产里数量极大（常占全部 string 一半以上） |
| 2 | 值是 GUID（8-4-4-4-12 hex）/16+ 位 hex 串/`Assets/...` 路径/URL 类（含 http 前缀，或无空格且形如 `域名/路径`、`scheme://...`；按钮/链接字段还可能塞密码字段值如 `password`） | tech | 即使叶子名是文本字段 |
| 3 | 叶子名 ∈ 通用文本叶子：`m_text`、`m_Text`、`_text`、`text`、`topText`、`bottomText`、`leftText`、`rightText`、`infoLeft`、`infoRight` | text | 无论什么类出现都可译（UI 文本/伤害数字弹出/tooltip 左右栏） |
| 4 | (类， 叶子) 命中上方速查表或下方确切映射 | text/name/format | |
| 5 | 类 ∈ {`GameCreator.Runtime.VisualScripting.Trigger`/`Conditions`/`Actions`} 且叶子 = `m_Value` | review | 视觉脚本 value 载荷混合，细分甄别。保留：下划线开头驼峰（shader/材质属性名 `_FadeAmount`/`_Color`/`_Alpha`，常占 review 大头）、PascalCase 标识符（`TabletopHeroSelected`）、状态词（`Enable`/`Disable`/`Toggle`/`none`）。可译：星期（Monday…Weekend）、亲属/角色词（mom/Daughter）、含空格的可读短语与整句（`Tabletop Party Core`） |
| 6 | 其余 | tech | **默认拒绝**：ScriptableObject 的 `m_Name`、`m_MethodName`、`m_TargetAssemblyTypeName`、`m_ObjectArgumentAssemblyTypeName`、UI Selectable 系 `m_NormalTrigger`/`m_HighlightedTrigger`/`m_PressedTrigger`/`m_SelectedTrigger`/`m_DisabledTrigger`、InputActionAsset 的 `m_Id`/`m_Path`/`m_Action`/`m_Groups`/`m_ExpectedControlType`/`m_ControlPath`/`m_BindingGroup`/`m_Name`、`InputActionReference.m_ActionId`、`AudioEventLibrary.key`、`Gallery.GrabAnimationLibrary.variantID`、`GraffitiSurfaceZone.sortingLayerName`、`UniversalRenderPipelineGlobalSettings.m_RenderingLayerNames`、`DebugManager.harnessStatus` 全是技术值 |

### (类， 叶子) 确切映射（速查表未覆盖的补充）

| scriptClass | 叶子字段 | 类别 | 内容 |
| --- | --- | --- | --- |
| `GameCreator.Runtime.Quests.Quest` | `m_Value` / `m_Name` | text / name | 任务描述 / 任务名（`m_String` 为 tech） |
| `GameCreator.Runtime.Stats.Stat` / `.Attribute` | `m_Value` / `m_Name` | text / name | 统计项描述 / 统计项名 |
| `GameCreator.Runtime.Stats.Class` | `m_Name` | name | 职业名 |
| `GameCreator.Runtime.Stats.Traits` | `m_Name`（`m_String`=tech） | name | 特质名 |
| `GameCreator.Runtime.Dialogue.Actor` | `m_Name` / `m_Value` | name | 说话角色名 |
| `GameCreator.Runtime.Common.UnityUI.TextPropertyString` / `.InputFieldTMPPropertyString` | `m_Value` | text | UI 绑定字符串属性 |
| `Fullscreen.NanoSave.Runtime.SaveSlotComponent` | `m_Value` | text | 存档位显示文本 |
| `SimpleTooltip` | `infoLeft` / `infoRight` | text | 悬浮提示左右栏 |
| `SlotMachineMinigame.SymbolDefinition` | `displayName` | name | 符号显示名 |
| `SlotMachineMinigame.SlotMachine` | `betFormat` / `winFormat` | format | `{0}` 金额格式串 |
| 自定义类 | `_defaultPlayerName` / `_defaultNpc1Name` / `_defaultNpc2Name` | name | 默认角色/NPC 名 |
| **自定义类 string 数组直接元素**（leaf=`Array`，如 `DialogueUI.lines.Array[i]`、`GraffitiStyle.wordPool.Array[i]`、`JumpScareCorpse.dialogueLines.Array[i]`、`onboardingLines.Array[i]`） | `Array` | review→text | **对白池/词池/提示行**——无引擎模板游戏最常见的隐藏载体：对白和叙事词常是自定义 MonoBehaviour 上的 `string[]`，fieldPath 末段为 `Array`。survey 的 `类|叶子` 分布出现大计数 `Array` 组时**必须抽查内容定性**；确认文本后把 `Array` 加入白名单。注意与 UI 文本组件区分：这类走 mono scope，不走 component |
| 自定义调试类 | `zones.Array[i].title` 等（leaf=`title`） | review | 调试 overlay 的区域标题（如 LevelPacingZoneOverlay），正常玩家不可见，通常排除 |

### 提取分类器实现要点（Python 骨架，可复用）

- `walk()` 递归收集 `(fieldPath, string)` 时在 `references.RefIds` 特判——只下钻 `RefIds[i].data` 并把路径记为 `RefIds[i].data...`（跳过 `type` 元数据块）。
- 脚本类名不靠 export 文件名，而用 `list_script_types outputFile` 落盘的 (fileId, pathId)→命名空间.类名 映射，从导出 JSON 的 `m_Script` PPtr 反查（失败回退文件名段并计数 `unmapped`）。注意映射文件名不与源文件名一一对应（候选 `{src}.json` 与 `{src}.assets.json`，详见 traps.md）。
- 递归 walk 用 `path+'.'+k` 拼路径会产生前导点（顶层字段是 `.nameText` 而非 `nameText`）：分类匹配用 `path.split('.')[-1]` 取叶子（含数组下标归一化，见 SKILL.md 回写节）。
- 每条可译 entry 附 `uid` = md5(原文) 前 8 位作去重/回写对齐键。产出单 JSON：`texts`（text/name/format）+ `review_value_strings` + `technical_strings` 三数组，`meta` 记录 per_source_file 统计与 top_script_classes 供汇报规模。

### 补充实战数据点

- 格式串可能含数字格式说明符（`Bet: ${0:N0}`）——翻译时整体保留占位符与格式说明符。
- 同一 value 高频重复（同一按钮文本出现 800+ 次）属正常，靠 uid 去重后翻译量大幅下降。
- 多行文本（含 `\n`/CRLF）占比虽小（一例 374/25018）但必须走 JSON Lines 并从原 jsonl 精确复制原文。
- TextAnimator 的动画标签名（`size`/`fade`/`wiggle`）落在 `Array` 叶子里，默认拒绝规则可正确归入 tech。
