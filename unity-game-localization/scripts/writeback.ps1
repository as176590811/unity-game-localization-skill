# writeback.ps1 — 附录 A4/A5/A6：映射回写（Newtonsoft.Json）、人工补翻覆盖、RefIds 兜底扫描
# PowerShell 5.1 骨架：用 .NET API 读写文件，规避编码/序列化陷阱（详见 references/traps.md PS5.1 三坑）

# ============ A4. 映射回写（en→zh 字典替换目标字段，Newtonsoft.Json） ============
# 必须用 Newtonsoft.Json 而非 ConvertTo-Json（PS5.1 解包单元素数组会破坏嵌套结构）。
# 给 JToken 赋字符串要 [JValue]::new(...) 显式包装。字典只含 to_translate 条目，
# keep 条目 map 到自身（不写盘）。
Add-Type -Path '<游戏目录>\BepInEx\plugins\XUnity.AutoTranslator\Translators\FullNET\Newtonsoft.Json.dll'
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
# 替换后重扫目标字段验证：剩余英文应全在 keep 列表（unexpected_miss=0）

# ============ A5. 人工修复漏译（en→zh 覆盖，JSON Lines 数据文件） ============
# 漏译条目（missTexts）人工翻译时，把目标原文与译文做成两个 JSON Lines 文件
# （目标原文从 unique_en.jsonl 原样复制保证精确，含换行/CRLF/特殊引号；译文用 \uXXXX 转义或 Escape-Json）
# targets.jsonl（原文，从 jsonl 原样复制） 与 fix_zh.jsonl（译文，JSON 编码）行号一一对应
# 脚本：遍历 en jsonl，若命中 targets[j] 则 zh[i] = fixZh[j]
# 注意多行文本换行符 CRLF/LF 必须与原文完全一致（从原 jsonl 复制而非手敲）

# ============ A6. 递归扫描 references.RefIds[].data 发现全部文本载体（避免漏译） ============
# 只扫 data（不扫 type/asm/rid 等元数据），按字段名区分可译（m_Value/m_Text）与技术
# （m_String/m_TargetAssemblyTypeName/m_MethodName）。Dialogue 的 GetStringString → data.m_Value
# 常被目标提取漏掉（物品/称号名、商店对白），此扫描可兜底。
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
