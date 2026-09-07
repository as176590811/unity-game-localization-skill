# unity-game-localization

Unity 游戏（.assets / dll）文本汉化的 AI Agent Skill 仓库。

本 skill 通过 `unity-assets` MCP 服务器，将 Unity 游戏内脚本化文本（对白、UI 文案、TextMeshProUGUI、伤害数字弹出文本等）定位、提取、批量翻译为简体中文并写回 `.assets` 文件；同时覆盖 `Assembly-CSharp.dll` 内硬编码 UI 文本（dnSpy MCP + dnfile 定位、#US 堆原地替换回写）。

## 适用场景

- 汉化 / 翻译 Unity 游戏对白、对话、UI 文案
- 文本存在于 MonoBehaviour 序列化字段（GameCreator 脚本、自定义脚本、TMP 组件）
- 支持引擎/框架：GameCreator、TextMeshPro、DamageNumbersPro、Utage 视觉小说引擎、Fungus 引擎、dll 内硬编码文本

## 工作流概览

| 环节 | 说明 |
| --- | --- |
| 1. 前置准备 | `open_file` + `set_mono_generator` 预设 Mono/IL2CPP 构建，`list_script_types` 定位脚本类 |
| 2. 定位与统计 | 识别文本载体类，`list_assets` / `scan_text` 枚举实例、评估规模 |
| 3. 导出与提取 | `export_all` 批量导出，本地脚本按目标字段提取、去重成 unique jsonl |
| 4. 分类决策 | 区分 text / name / format / review / tech，交用户决策翻译范围 |
| 5. 批量翻译 | `translate_batch` 或直连本地 LLM HTTP 服务，JSON Lines 格式 |
| 6. 回写与验证 | `import_json_batch` 回写，备份后覆盖，终验残留文本 |
| 7. 代码内硬编码 | Asset 遗漏复查，dnSpy MCP + dnfile 定位 dll 文本，#US 堆原地替换 |
| 8. 差集审计 | 全量字符串差集复查，确认无遗漏 |

## 前置条件

- [`unity-assets`](https://github.com/as176590811/UnityAssets-mcp) MCP（需含：`scan_text` / `locate_text` / `translate_batch` / `import_json_batch` / `list_script_types` / `export_all`）
- 本地 LLM 翻译服务 [XUnityToolkit-WebUI](https://github.com/HanFengRuYue/XUnityToolkit-WebUI)（默认 `http://127.0.0.1:51821/api/translate`，与 XUnity.AutoTranslator LLMTranslate 同协议）
- （dll 汉化需）[dnSpy MCP](https://github.com/KernelErr/dnSpy.Extension.MCP) 与 Python `dnfile`

## 目录结构

```
skills/
├── .gitignore
├── LICENSE
├── README.md
└── unity-game-localization/
    ├── SKILL.md                    # 主流程：前置准备 → 提取 → 分类 → 翻译 → 回写 → 审计
    ├── references/
    │   ├── class-fields.md         # 脚本类→文本字段字典与分类法（提取/分类/回写共用）
    │   ├── engines.md              # Utage / Fungus 引擎专项定位与提取规则
    │   ├── traps.md                # 工具行为陷阱与排查（按症状查）
    │   └── dll-patch.md            # Assembly-CSharp.dll 硬编码文本补丁
    └── scripts/                    # PowerShell / Python 脚本骨架
        ├── extract_unique_en.ps1   # 提取独特英文 → 分类筛选 → 合并译文
        ├── writeback.ps1           # 映射回写 / 人工补翻 / RefIds 兜底扫描
        ├── translate_direct.py     # 直连 HTTP 翻译 + 漏译重试 + strip 回写 + 残留审计
        ├── scan_ldstr.py           # 程序集 ldstr 全量扫描（dnfile）
        └── patch_us_heap.py        # #US 堆原地替换回写骨架
```

## 详细文档

主流程见 **[unity-game-localization/SKILL.md](./unity-game-localization/SKILL.md)**，其内附「按需读参考文件」渐进披露引导表：

- [references/class-fields.md](./unity-game-localization/references/class-fields.md) —— 脚本类→文本字段字典、text/name/format/review/tech 分类法
- [references/engines.md](./unity-game-localization/references/engines.md) —— Utage（视觉小说）与 Fungus 引擎专项定位与提取规则
- [references/traps.md](./unity-game-localization/references/traps.md) —— 工具行为陷阱与排查
- [references/dll-patch.md](./unity-game-localization/references/dll-patch.md) —— Assembly-CSharp.dll 硬编码文本补丁
- [scripts/](./unity-game-localization/scripts/) —— 可复用的 PowerShell / Python 脚本骨架

## 说明

本 skill 只描述可复用的工作流，不在文档中固化具体游戏的 pathId、昵称、译文等任务数据。游戏名、翻译风格、是否含成人内容等需在执行时询问用户。