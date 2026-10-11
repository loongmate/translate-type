# 方寸输入法逐项测试结果

检查对象为 build 11。`PASS` 表示本条指定条件通过；`FAIL` 是未达到明确的内容或编辑要求；`REVIEW` 是需要人工评估的结果，不算通过。这里的原文和输入均为测试构造文本。

运行时刻与文件摘要见 [检查环境](build11-audit-context.json)。完整字段保存在同目录 JSON 中；本文便于阅读。

## 组句与真实拼音引擎

共 73 项，通过 56，失败 9，待评审 8。测试层：真实 Rime 与 CompositionSession，非系统端到端测试。

[原始结果](input-behavior-build11.json)

### 首选词样本

这些样本在测试词库尚未被选词操作训练前采集。首屏未发现目标时记 0，并不代表整个词库不存在该表达。

| 编号 | 输入 | 目标表达 | 实际首选 | 目标首屏排名 | 状态 |
| --- | --- | --- | --- | --- | --- |
| Q01 | `nihao` | 你好 | 你好 | 1 | PASS |
| Q02 | `nishuode` | 你说的 | 你说的 | 1 | PASS |
| Q03 | `zhongwenshuru` | 中文输入 | 中文输入 | 1 | PASS |
| Q04 | `xuancikenengbuzhengque` | 选词可能不正确 | 选词可能不正确 | 1 | PASS |
| Q05 | `ceshi` | 测试 | 测试 | 1 | PASS |
| Q06 | `ceshiyeyaochongfenkaolvyiyongxing` | 测试也要充分考虑易用性 | 测试也要充分考虑易用性 | 1 | PASS |
| Q07 | `woxiangqubeijing` | 我想去北京 | 我想去北京 | 1 | PASS |
| Q08 | `jintianxiawusandiankaihui` | 今天下午三点开会 | 今天下午三点开会 | 1 | PASS |
| Q09 | `women` | 我们 | 我们 | 1 | PASS |
| Q10 | `xi'an` | 西安 | 西安 | 1 | PASS |
| Q11 | `chang'an` | 长安 | 长安 | 1 | PASS |
| Q12 | `chongqing` | 重庆 | 重庆 | 1 | PASS |
| Q13 | `yinhang` | 银行 | 银行 | 1 | PASS |
| Q14 | `hangye` | 行业 | 行业 | 1 | PASS |
| Q15 | `fangcunshurufa` | 方寸输入法 | 方寸输入法 | 1 | PASS |
| Q16 | `tuopanlidelogo` | 托盘里的logo | 托盘里的logo | 1 | PASS |
| Q17 | `zhichiAPI` | 支持API | 支持API | 1 | PASS |
| Q18 | `woyaoxiugaiBug` | 我要修改Bug | 我要修改Bug | 1 | PASS |
| Q19 | `wozaiGitHubtijiaolePR` | 我在GitHub提交了PR | 我再跟it湖北提交了譬如 | 0 | REVIEW |
| Q20 | `zhegeApphenhao` | 这个App很好 | 这个App很好 | 1 | PASS |
| Q21 | `nvhai` | 女孩 | 女孩 | 1 | PASS |
| Q22 | `lvse` | 绿色 | 绿色 | 1 | PASS |

### 输入操作

后续用例保留真实 Rime 学习行为。选择结果与当时展示的候选比较；“你耗”等词是测试中选择其他 hao 候选造成的词频变化，不能单独归为选词按钮错误。

| 编号 | 操作 | 预期 | 实际内容与状态 | 状态 |
| --- | --- | --- | --- | --- |
| SEL-C-1 | hao → 数字 1 | 好 | 提交=`好`; 光标=0; 可翻译=False | PASS |
| SEL-C-2 | hao → 数字 2 | 号 | 提交=`号`; 光标=0; 可翻译=False | PASS |
| SEL-C-3 | hao → 数字 3 | 浩 | 提交=`浩`; 光标=0; 可翻译=False | PASS |
| SEL-C-4 | hao → 数字 4 | 豪 | 提交=`豪`; 光标=0; 可翻译=False | PASS |
| SEL-C-5 | hao → 数字 5 | 耗 | 提交=`耗`; 光标=0; 可翻译=False | PASS |
| SPACE-C | hao → ↓ → Space | 豪 | 提交=`豪`; 光标=0; 可翻译=False | PASS |
| PAGE-C | hao → PageDown → 2 | 昊 | 提交=`昊`; 光标=0; 可翻译=False | PASS |
| CHOOSE-C | hao → choose(2) | 耗 | 提交=`耗`; 光标=0; 可翻译=False | PASS |
| PARTIAL-C | nihao → ←×3 → Space → Space | 你耗 | 提交=`你耗`; 光标=0; 可翻译=False | PASS |
| INVALID-C | hao → 9 | 保留 hao，不确认其他候选 | 预编辑=`hao`; 光标=3; 可翻译=False | PASS |
| PUNCT-C | nihao → Space → . | 你耗。 | 提交=`你耗。`; 光标=0; 可翻译=False | PASS |
| PUNCT-SELECT-C | hao → ↓ → , | 豪， | 提交=`豪，`; 光标=0; 可翻译=False | PASS |
| RAW-C | logo → Enter | logo | 提交=`logo`; 光标=0; 可翻译=False | PASS |
| PARTIAL-RAW-C | nihao → ←×3 → Space（你）→ Enter | 你hao | 提交=`nihao`; 光标=0; 可翻译=False | FAIL |
| PARTIAL-SHIFT-C | nihao → ←×3 → Space（你）→ 切英文 | 你hao | 提交=`nihao`; 光标=0; 可翻译=False | FAIL |
| FLUSH-C | ni│hao → flushOriginal（失焦路径） | 完整保留 nihao / 你hao / 你耗 | 提交=`你`; 光标=0; 可翻译=False | FAIL |
| SEL-T-1 | hao → 数字 1 | 豪 | 草稿=`豪`; 光标=1; 可翻译=True | PASS |
| SEL-T-2 | hao → 数字 2 | 耗 | 草稿=`耗`; 光标=1; 可翻译=True | PASS |
| SEL-T-3 | hao → 数字 3 | 昊 | 草稿=`昊`; 光标=1; 可翻译=True | PASS |
| SEL-T-4 | hao → 数字 4 | 浩 | 草稿=`浩`; 光标=1; 可翻译=True | PASS |
| SEL-T-5 | hao → 数字 5 | 号 | 草稿=`号`; 光标=1; 可翻译=True | PASS |
| SPACE-T | hao → ↓ → Space | 耗 | 草稿=`耗`; 光标=1; 可翻译=True | PASS |
| PAGE-T | hao → PageDown → 2 | 郝 | 草稿=`郝`; 光标=1; 可翻译=True | PASS |
| CHOOSE-T | hao → choose(2) | 昊 | 草稿=`昊`; 光标=1; 可翻译=True | PASS |
| PARTIAL-T | nihao → ←×3 → Space → Space | 你耗 | 草稿=`你耗`; 光标=2; 可翻译=True | PASS |
| INVALID-T | hao → 9 | 保留 hao，不确认其他候选 | 预编辑=`hao`; 光标=3; 可翻译=False | PASS |
| PUNCT-T | nihao → Space → . | 你耗。 | 草稿=`你耗。`; 光标=3; 可翻译=True | PASS |
| PUNCT-SELECT-T | hao → ↓ → , | 豪， | 草稿=`豪，`; 光标=2; 可翻译=True | PASS |
| RAW-T | logo → Enter | logo | 草稿=`logo`; 光标=4; 可翻译=True | PASS |
| PARTIAL-RAW-T | nihao → ←×3 → Space（你）→ Enter | 你hao | 草稿=`nihao`; 光标=5; 可翻译=True | FAIL |
| PARTIAL-SHIFT-T | nihao → ←×3 → Space（你）→ 切英文 | 你hao | 草稿=`nihao`; 光标=5; 可翻译=True | FAIL |
| FLUSH-T | ni│hao → flushOriginal（失焦路径） | 完整保留 nihao / 你hao / 你耗 | 提交=`你`; 光标=0; 可翻译=False | FAIL |
| EMPTY-SPACE | Space | 一个空格 | 提交=` `; 光标=0; 可翻译=False | PASS |
| DECIMAL-C | 3.14 | 需确定整段英文识别规则；不得当作中文正确率通过项 | 提交=`3.14`; 光标=0; 可翻译=False | REVIEW |
| DECIMAL-EN | 3.14 | 3.14 | 提交=`3.14`; 光标=0; 可翻译=False | PASS |
| EMAIL-C | test@example.com | 需确定整段英文识别规则；不得当作中文正确率通过项 | 提交=`test@example。`; 预编辑=`com`; 光标=3; 可翻译=False | REVIEW |
| EMAIL-EN | test@example.com | test@example.com | 提交=`test@example.com`; 光标=0; 可翻译=False | PASS |
| URL-C | https://example.com/a?x=1 | 需确定整段英文识别规则；不得当作中文正确率通过项 | 提交=`HTTPS：//example。com/啊？下=1`; 光标=0; 可翻译=False | REVIEW |
| URL-EN | https://example.com/a?x=1 | https://example.com/a?x=1 | 提交=`https://example.com/a?x=1`; 光标=0; 可翻译=False | PASS |
| CODE-C | API_v2 | 需确定整段英文识别规则；不得当作中文正确率通过项 | 提交=`API_vacancies`; 光标=0; 可翻译=False | REVIEW |
| CODE-EN | API_v2 | API_v2 | 提交=`API_v2`; 光标=0; 可翻译=False | PASS |
| LONE-PUNCT | 开启译英 → . | 展示实际状态，是否允许仅标点翻译需决定 | 草稿=`。`; 光标=1; 可翻译=True | REVIEW |
| DRAFT-LEFT | 译英 → nihao → Space → ← | 光标从你好末尾左移一字，不上屏 | 草稿=`你耗`; 光标=2; 可翻译=True | FAIL |
| DRAFT-BACKSPACE | 译英 → nihao → Space → Backspace | 你 | 草稿=`你`; 光标=1; 可翻译=True | PASS |
| DRAFT-SPACE | 译英 → nihao → Space → Space | 你耗 后有一个空格 | 草稿=`你耗 `; 光标=3; 可翻译=True | PASS |
| DRAFT-ESC | 译英 → nihao → Space → shijie → Esc | 当前实现会清空整段；需要决定分层取消规则 | 内容为空; 光标=0; 可翻译=False | REVIEW |
| TAB-TAIL | 译英 → ni│hao → Tab | 完整保留 nihao / 你hao / 你耗 | 提交=`你`; 光标=0; 可翻译=False | FAIL |
| TOGGLE-TAIL | 译英 → ni│hao → 关闭译英 | 完整保留 nihao / 你hao / 你耗 | 提交=`你`; 光标=0; 可翻译=False | FAIL |
| BLOCK-TRANSLATION | 你好 + ni│hao → Ctrl+Enter | 全文与光标保持不变，不启动翻译 | 草稿=`你耗`; 预编辑=`nihao`; 光标=4; 可翻译=False | PASS |
| DRAFT-RETURN | 译英 → nihao → Space → Enter | 当前 Enter 中文上屏；段内换行操作待设计 | 提交=`你耗`; 光标=0; 可翻译=False | REVIEW |
| LONG-DRAFT | 重复 60 次 nihao → Space → . | 60 次实际高亮的选词与句号完整保留 | 草稿=`你耗。你耗。你耗。你耗。你耗。你耗。你耗。你耗。你耗。你耗。你耗。你耗。你耗。你耗。你耗。你耗。你耗。你耗。你耗。你耗。…（共 180 字符；完整内容见 JSON）`; 光标=180; 可翻译=True | PASS |

## 控制器与真实文本视图

共 6 项，通过 1，失败 4，待评审 1。测试层：真实 IMK 控制器与 NSTextView，人工投递事件；非系统端到端。

[原始结果](client-behavior-build11.json)

| 编号 | 操作 | 预期 | 文本视图实际内容 | 预编辑范围 | 状态 |
| --- | --- | --- | --- | --- | --- |
| CLIENT-CLICK | ni│hao → 输入区域鼠标按下 | 保留光标后的 hao，不能只剩你 | `你` | `{1, 0}` | FAIL |
| CLIENT-DEACTIVATE | ni│hao → deactivateServer | 保留光标后的 hao，不能只剩你 | `你` | `{1, 0}` | FAIL |
| CLIENT-PARTIAL-ENTER | ni│hao → Space → Enter | 已选的你保留，只把 hao 原样确认 | `nihao` | `{5, 0}` | FAIL |
| CLIENT-DRAFT-EDIT | 译英 → nihao → Space → ← → Backspace | 光标在你和好之间时退格，剩下好 | `你` | `{0, 1}` | FAIL |
| CLIENT-BLOCK | 译英 → ni│hao → Ctrl+Enter | 输入和光标保持不变 | `nihao` | `{0, 5}` | PASS |
| CLIENT-PUNCT | 译英 → nihao → Space → 鼠标按下 → . | 记录已上屏中文和单独待确认句号的边界 | `你好。` | `{2, 1}` | REVIEW |

## 如何阅读失败

失败脚本会返回退出码 1，但继续跑完其他用例并保存结果。相同缺陷在普通中文、译英以及客户端层重复出现，因此失败条目数不等于独立缺陷数。系统输入路由、真实鼠标命中候选、其他应用兼容性和完整日常任务仍需单独验收。

[返回输入行为与易用性验收](../input-behavior-and-usability.md)
