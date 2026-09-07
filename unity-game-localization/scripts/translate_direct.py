# translate_direct.py — 直连 HTTP 批量翻译 + 漏译重试 + strip 匹配回写 + 残留审计
# 适用：MCP translate_batch 客户端 30 秒超时的回退，以及 Fungus 等数据驱动游戏的全流程
# 并发数以用户告知为准；漏译清单必须存 JSON/JSONL，切勿明文行（多行字符串会拆断）

# ① 直连翻译（MCP translate_batch 超时时的回退；并发数以用户告知为准）
import json, os, urllib.request, threading, queue, time
ENDPOINT = 'http://127.0.0.1:51821/api/translate'
def call(texts, game='<gameId>'):   # gameId 无配置时传任意标识串
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
# 技术键黑名单按游戏补全（方法参数键/状态键/资源键；误译写回会破坏游戏逻辑）
TECH_KEYS = {'speed','critical','max','attack','weak','normal','strong','cheat','delete',
             'tough','dexterity','power','evation','luck','hp','wood','iron','stone','cloth',
             'leather','magi','soul','fera'}
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
