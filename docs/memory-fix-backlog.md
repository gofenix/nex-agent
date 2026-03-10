# Memory 修复排期建议

这份 backlog 按“先保证正确性，再保证检索一致性，最后收敛设计”的顺序排。

## P0

### 1. 先修磁盘与索引不一致
- 修改 `write_long_term/1`，让长期记忆写盘后同步刷新 `Memory.Index` 中的 `:memory` 文档。
- 修改 `append_history/1`，让 history 追加后同步刷新 `:history` 文档。
- 直接沿用 [memory_audit_test.exs](/Users/fenix/github/nex-agent/test/nex/agent/memory_audit_test.exs) 里的回归场景，确保“写完立刻能搜到”。
- 依赖关系：无。

### 2. 让 `store/1` 变成真正可回读的数据
- 明确 `store/1` 的定位：
  - 要么走标准 daily log 格式；
  - 要么保留 `STORE` 格式，但补齐 parser / rebuild / search。
- 修完后，保证 `store/1` 写入的数据能被回读或检索发现。
- 依赖关系：无。

## P1

### 3. 让长期记忆索引兼容无标题文件
- 对非空但没有 `##` 标题的 `MEMORY.md`，按一个隐式 section 处理。
- 保留当前已有标题时的 section 语义。
- 增加空文件、单标题、多标题、无标题四类测试。
- 依赖关系：无。

### 4. 对齐 consolidation 结果解析的鲁棒性
- 审核 tool-call arguments 的解码链，统一支持：
  - map
  - JSON 字符串
  - list 包一层 dict
- 明确 malformed consolidation 输出时应返回“失败”还是“安全 no-op”。
- 增加缺 `history_entry`、缺 `memory_update`、没有 tool call、参数格式异常等测试。
- 依赖关系：无。

### 5. 收紧 `get_history/2` 的清洗边界
- 先定义哪些 partial turn 应该保留，哪些脏数据应该清掉。
- 先补 turn 边界测试，再改清洗逻辑，避免修成另一种数据丢失。
- 依赖关系：无。

## P2

### 6. 收敛 memory 注入策略
- 在下面两种策略里选一个默认方案：
  - 小体量 memory：保留完整 `MEMORY.md`，不再附加 runtime snippets。
  - 检索优先：长期记忆只放摘要，细节靠 runtime 检索。
- 最终要求是 prompt 结构稳定、重复低、大小可控。
- 依赖关系：先完成 P0，保证检索结果可信。

### 7. 把“谁是事实真相源”写清楚
- 在代码注释和文档里明确：
  - 哪些 API 改磁盘
  - 哪些 API 改索引
  - 哪些路径需要 rebuild
- 同时把模块文档和真实磁盘格式对齐，避免文档描述与实现继续漂移。
- 依赖关系：建议在前面行为修正之后统一收尾。
