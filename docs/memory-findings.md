# Memory 审计结论

这份清单只保留两类内容：
- 已经能从源码行为确认的问题
- 已经有最小复现测试支撑的问题或高风险偏差

## P0

### 1. `write_long_term/1` 后搜索索引会过期
- 类型：Bug
- 是否属于 nanobot 对标差异：是。nanobot 直接把文件当真相源，没有这类“磁盘已更新但索引没更新”的漂移。
- 影响：新写入 `MEMORY.md` 的内容，`memory_search` 立刻搜不到，除非手动重建索引或重启进程。
- 根因：`Memory.search/2` 优先走 `Memory.Index.search/2`；但 `write_long_term/1` 只改磁盘，不通知索引刷新。
- 复现：运行 [memory_audit_test.exs](/Users/fenix/github/nex-agent/test/nex/agent/memory_audit_test.exs) 里的 `write_long_term does not refresh memory index until rebuild`。
- 证据：[memory.ex](/Users/fenix/github/nex-agent/lib/nex/agent/memory.ex)、[index.ex](/Users/fenix/github/nex-agent/lib/nex/agent/memory/index.ex)
- 建议修复：每次写长期记忆后，至少刷新 `:memory` 文档对应的索引。
- 建议回归测试：`write_long_term/1` 之后立刻 `Memory.search/2`，应能搜到新内容。

### 2. `append_history/1` 后历史索引也会过期
- 类型：Bug
- 是否属于 nanobot 对标差异：是。nanobot 读取 `HISTORY.md` 时不依赖索引，所以不会出现文件和搜索结果不一致。
- 影响：新写入 `HISTORY.md` 的历史，短时间内无法被 `memory_search` 检索到。
- 根因：`append_history/1` 只写磁盘，不更新 `Memory.Index`。
- 复现：运行 [memory_audit_test.exs](/Users/fenix/github/nex-agent/test/nex/agent/memory_audit_test.exs) 里的 `append_history does not refresh history index until rebuild`。
- 证据：[memory.ex](/Users/fenix/github/nex-agent/lib/nex/agent/memory.ex)
- 建议修复：为 history 做增量入索引，或者每次追加后做有范围的重建。
- 建议回归测试：`append_history/1` 后立即 `Memory.search(query, source: :history)` 应能返回新条目。

### 3. `store/1` 写入的数据无法被现有 parser 回读
- 类型：Bug
- 是否属于 nanobot 对标差异：否。这是 `nex-agent` 自己扩展出来的能力。
- 影响：`store/1` 写进去的数据虽然落盘了，但 `read_all_entries/0`、BM25 rebuild、fallback search 都看不到。
- 根因：`store/1` 写的是 `## STORE:` 格式，而 `parse_entries/1` 只认识 `## timestamp - id - task: result`。
- 复现：运行 [memory_audit_test.exs](/Users/fenix/github/nex-agent/test/nex/agent/memory_audit_test.exs) 里的 `store writes entries that read_all_entries cannot parse back`。
- 证据：[memory.ex](/Users/fenix/github/nex-agent/lib/nex/agent/memory.ex)
- 建议修复：二选一。
  - 把 `store/1` 改写成标准 daily log 格式。
  - 或者补一条专门解析 `STORE` 块的回读和索引路径。
- 建议回归测试：`store/1` 后的数据必须能被读取或搜索链路发现。

## P1

### 4. 没有 `##` 标题的 `MEMORY.md` 会进 prompt，但不会进索引
- 类型：Bug
- 是否属于 nanobot 对标差异：是。nanobot 把整个 `MEMORY.md` 当作一整段长期记忆，不要求标题结构。
- 影响：模型能在 system prompt 里看到这段记忆，但 `memory_search` 却永远搜不到它。
- 根因：`read_memory_sections/0` 会直接丢弃不是以 `## ` 开头的内容。
- 复现：运行 [memory_audit_test.exs](/Users/fenix/github/nex-agent/test/nex/agent/memory_audit_test.exs) 里的 `read_memory_sections ignores unheaded MEMORY.md content while long-term prompt still includes it`。
- 证据：[memory.ex](/Users/fenix/github/nex-agent/lib/nex/agent/memory.ex)
- 建议修复：对没有标题但非空的 `MEMORY.md`，按一个隐式 section 入索引。
- 建议回归测试：headerless `MEMORY.md` 也应该生成 1 条可搜索的 memory 文档。

### 5. `get_history/2` 对 tool history 的清洗比 nanobot 更激进
- 类型：风险性偏差
- 是否属于 nanobot 对标差异：是。nanobot 只做“从 user turn 开始”的对齐，不主动修剪这类内容。
- 影响：在截断边界或半截 turn 场景下，历史中本来可能还有价值的 tool call 上下文会被去掉。
- 根因：`sanitize_tool_pairs/1` 会清掉 orphaned `tool_calls` 和 orphaned tool results。
- 复现：运行 [memory_audit_test.exs](/Users/fenix/github/nex-agent/test/nex/agent/memory_audit_test.exs) 里的 `strips orphaned tool calls that nanobot would keep in unconsolidated history`。
- 证据：[session.ex](/Users/fenix/github/nex-agent/lib/nex/agent/session.ex)
- 建议修复：把这层清洗改成更保守的策略，或者至少做边界感知。
- 建议回归测试：同时覆盖“应该保留的半截 turn”和“真正脏数据应清除”两类场景。

## P2

### 6. 同一份 memory 可能同时通过静态注入和检索注入暴露
- 类型：风险性偏差
- 是否属于 nanobot 对标差异：是。nanobot 只把长期记忆静态注入一次，并把 runtime context 合并进 user message。
- 影响：同一份事实既可能出现在 `## Long-term Memory`，又可能以检索片段形式再次出现在 prompt 里，增加 token 和重复信息。
- 根因：`build_system_prompt/1` 注入 `MEMORY.md`；`build_messages/6` 又会把检索出的 runtime memory 追加到 system prompt 末尾。
- 复现：运行 [memory_audit_test.exs](/Users/fenix/github/nex-agent/test/nex/agent/memory_audit_test.exs) 里的 `long-term memory is injected into prompt while the same content is also retrievable via search`。
- 证据：[context_builder.ex](/Users/fenix/github/nex-agent/lib/nex/agent/context_builder.ex)、[system_prompt.ex](/Users/fenix/github/nex-agent/lib/nex/agent/system_prompt.ex)
- 建议修复：一次请求里只保留一种主 memory 注入策略，或者在拼 prompt 前做去重。
- 建议回归测试：当检索结果和长期记忆内容相同，不应重复拼进 prompt。
