# Memory 对标 nanobot 一览表

这份表按整条 memory 链路对比 `nex-agent` 和 `nanobot`：
`consolidate -> session.last_consolidated -> get_history -> context 注入 -> MEMORY/HISTORY 读写 -> search/index 回读`

| 能力点 | nanobot 行为 | nex-agent 行为 | 差异类型 | 风险 |
| --- | --- | --- | --- | --- |
| 长期记忆存储 | 把 `memory/MEMORY.md` 当成完整文本直接读写。 | 也读写 `memory/MEMORY.md`，但搜索索引依赖 `##` 标题切分。 | 风险性偏差 | 高 |
| 长期记忆注入 prompt | 只把长期记忆完整注入一次到 system prompt。 | system prompt 注入长期记忆，同时可能再附加 `Memory.Index` 检索出的 `Relevant Memories`。 | 风险性偏差 | 中 |
| 历史归档写入 | 向 `HISTORY.md` 追加可 grep 的自然语言段落。 | 向 `HISTORY.md` 追加带时间戳的段落。 | 有意差异 | 低 |
| 历史回读 | 没有索引层，文件内容就是唯一真相。 | `read_history/0` 能解析文件，但搜索依赖 `Memory.Index` 是否已重建。 | Bug | 高 |
| consolidation 结果解析 | 能接受 tool args 是 `dict`、JSON 字符串、list 包一层 dict。 | 这条链能处理 map 和 JSON 字符串，但对 list 包装参数不如 nanobot 一致。 | 风险性偏差 | 中 |
| consolidation 失败语义 | 没有 tool call 或参数异常时返回 `False`。 | 很多异常/缺字段场景会返回 `{:ok, session}`，等于跳过这次 consolidate。 | 风险性偏差 | 中 |
| session history 对齐 | 只做一件事：丢掉开头不是 user 的消息，让 history 从完整 user turn 开始。 | 除了按 user turn 对齐，还会额外清洗 orphaned tool call / tool result。 | 风险性偏差 | 中 |
| tool pair 保留 | 保留原始未 consolidate 的历史，只做前导对齐。 | 会更激进地修剪不成对的 tool 记录。 | 风险性偏差 | 中 |
| 日志型 memory append | 追加到 memory 文件，后续读取还是直接走文件。 | `append/3` 追加 daily log 后，还会增量更新 `Memory.Index`。 | 有意差异 | 低 |
| 任意结构化 store | 没有对应能力。 | `store/1` 会写入 `## STORE:` 块，但现有 parser 读不回来。 | Bug | 高 |
| search 的真实数据源 | 没有独立索引，`MEMORY.md` / `HISTORY.md` 就是数据源。 | 搜索优先走 `Memory.Index`；fallback 只扫 daily logs，不扫 `MEMORY.md` / `HISTORY.md`。 | Bug | 高 |
| 索引新鲜度 | 不适用。 | `append/3` 会更新索引，但 `write_long_term/1`、`append_history/1`、`store/1` 不会。 | Bug | 高 |

## 复现锚点

- Session 清洗行为复现：[memory_audit_test.exs](/Users/fenix/github/nex-agent/test/nex/agent/memory_audit_test.exs)
- Memory / Index 实现：[memory.ex](/Users/fenix/github/nex-agent/lib/nex/agent/memory.ex)、[index.ex](/Users/fenix/github/nex-agent/lib/nex/agent/memory/index.ex)
- Context 注入链路：[context_builder.ex](/Users/fenix/github/nex-agent/lib/nex/agent/context_builder.ex)、[system_prompt.ex](/Users/fenix/github/nex-agent/lib/nex/agent/system_prompt.ex)
