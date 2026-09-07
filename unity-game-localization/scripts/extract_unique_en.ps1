# extract_unique_en.ps1 — 附录 A1/A2/A3：提取独特英文文本 → 分类筛选 → 合并译文回全集
# PowerShell 5.1 骨架：按目标类改 m_Script.m_PathID 过滤值与字段名
# （目标类与字段路径查 references/class-fields.md，如 Dialogue->data.m_Text.m_Text、TextMeshProUGUI->m_text）
# 中文字面量不能写进 .ps1 源码（GBK 解析崩溃），统一放外部 UTF-8 数据文件或用 [char]0xXXXX 构造

# ============ A1. 提取独特英文文本 → jsonl（按目标字段过滤） ============
$dir = '<导出目录>'            # export_all 的输出目录
$outJsonl = '<工作目录>\unique_en.jsonl'

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

# ============ A2. 分类筛选（保留清单 + 角色名译名表） ============
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

# ============ A3. 合并译文回全集（按索引覆盖） ============
$enLines = [IO.File]::ReadAllLines('unique_en.jsonl', [Text.Encoding]::UTF8)
$idxLines = [IO.File]::ReadAllLines('idx.txt', [Text.Encoding]::UTF8)
$trZh = [IO.File]::ReadAllLines('to_translate_zh_fixed.jsonl', [Text.Encoding]::UTF8)
$out = New-Object 'System.Collections.Generic.List[string]'
for ($i = 0; $i -lt $enLines.Count; $i++) { $out.Add($enLines[$i]) }
for ($i = 0; $i -lt $idxLines.Count; $i++) { $out[[int]$idxLines[$i]] = $trZh[$i] }
# names 表按 en 匹配覆盖对应索引
# keep 条目保持原样
[IO.File]::WriteAllLines('unique_zh.jsonl', $out, (New-Object System.Text.UTF8Encoding($false)))
