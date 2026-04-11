---
theme: seriph
title: NexAgent
titleTemplate: '%s'
info: |
  NexAgent 对外分享
class: text-left
drawings:
  persist: false
transition: slide-left
mdc: true
fonts:
  sans: IBM Plex Sans
  serif: IBM Plex Sans
  mono: JetBrains Mono
---

<style>
:root {
  --nx-bg: #0b1020;
  --nx-panel: #11192e;
  --nx-panel-2: #0f1730;
  --nx-line: #233253;
  --nx-line-2: #30436b;
  --nx-text: #e7eefc;
  --nx-text-dim: #97a7cb;
  --nx-blue: #67b7ff;
  --nx-cyan: #69e0ff;
  --nx-amber: #ffbf69;
  --nx-red: #ff7d7d;
  --nx-green: #7be0b0;
}

.slidev-layout {
  background-color: #09111f;
  background-image:
    linear-gradient(rgba(63, 83, 122, 0.14) 1px, transparent 1px),
    linear-gradient(90deg, rgba(63, 83, 122, 0.14) 1px, transparent 1px),
    linear-gradient(180deg, #08101f 0%, #0a1324 100%);
  background-size: 40px 40px, 40px 40px, auto;
  color: var(--nx-text);
}

.nx-label {
  display: inline-flex;
  border: 1px solid var(--nx-line-2);
  background: rgba(103, 183, 255, 0.08);
  color: var(--nx-cyan);
  padding: 0.35rem 0.7rem;
  border-radius: 999px;
  font-size: 0.72rem;
  text-transform: uppercase;
  letter-spacing: 0.18em;
}

.nx-panel {
  background: rgba(15, 23, 42, 0.96);
  border: 1px solid var(--nx-line);
  border-radius: 28px;
  box-shadow: 0 14px 30px rgba(3, 7, 15, 0.28);
}

.nx-panel-soft {
  background: rgba(16, 24, 44, 0.82);
  border: 1px solid var(--nx-line);
  border-radius: 24px;
}

.nx-title {
  color: #f7fbff;
  letter-spacing: -0.03em;
  line-height: 1.05;
}

.nx-muted {
  color: var(--nx-text-dim);
}

.nx-accent {
  color: var(--nx-blue);
}

.nx-grid-2 {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 1.1rem;
}

.nx-card {
  background: rgba(15, 23, 42, 0.94);
  border: 1px solid var(--nx-line);
  border-radius: 22px;
  padding: 1.1rem 1.2rem;
}

.nx-key {
  color: var(--nx-cyan);
  font-size: 0.74rem;
  text-transform: uppercase;
  letter-spacing: 0.18em;
}

.nx-quote {
  border-left: 3px solid var(--nx-blue);
  padding-left: 1rem;
  color: #dce8ff;
}

.nx-compare {
  position: relative;
}

.nx-compare::after {
  content: "→";
  position: absolute;
  left: calc(50% - 0.6rem);
  top: 50%;
  transform: translateY(-50%);
  color: var(--nx-blue);
  font-size: 1.6rem;
  font-weight: 700;
}

.nx-chip {
  display: inline-flex;
  align-items: center;
  padding: 0.16rem 0.58rem;
  border-radius: 999px;
  border: 1px solid var(--nx-line-2);
  background: rgba(103, 183, 255, 0.08);
  color: #d7e8ff;
  font-family: "JetBrains Mono", monospace;
  font-size: 0.9em;
  line-height: 1.2;
  white-space: nowrap;
}

.nx-chip-skill {
  background: rgba(105, 224, 255, 0.08);
  color: var(--nx-cyan);
}

.nx-chip-tool {
  background: rgba(123, 224, 176, 0.08);
  color: var(--nx-green);
}

.nx-chip-code {
  background: rgba(255, 125, 125, 0.08);
  color: #ffb3c1;
}
</style>

<div class="h-full grid grid-cols-[1.04fr_0.96fr] gap-8 items-center">
  <div class="rounded-[30px] bg-[rgba(10,17,31,.96)] p-10 border border-[var(--nx-line)] shadow-[0_26px_50px_rgba(0,0,0,.24)] relative overflow-hidden">
    <div class="absolute inset-x-0 top-0 h-[1px] bg-[rgba(103,183,255,.25)]"></div>
    <div class="absolute right-0 top-0 h-full w-[1px] bg-[rgba(103,183,255,.12)]"></div>
    <div class="nx-label">gofenix / NexAgent</div>
    <h1 class="nx-title mt-6 !text-7xl !font-semibold">NexAgent</h1>
    <div class="mt-5 text-[1.8rem] leading-[1.26] max-w-180">
      从“养龙虾”到
      <br />
      长期运行的 Agent 系统
    </div>
    <div class="nx-panel mt-10 px-7 py-6 max-w-150">
      <div class="text-xl leading-relaxed">
        为什么在 OpenClaw 之后，
        <span class="nx-accent">我们还要再做一个自己的 agent</span>？
      </div>
      <div class="mt-3 nx-muted text-base leading-relaxed">
        这次分享关心的不是“再做一个 demo”，而是 agent 如何作为一个系统继续存在。
      </div>
    </div>
  </div>
  <div>
    <img src="./assets/cover-panel.svg" class="w-full rounded-[28px] shadow-2xl" />
  </div>
</div>

---
layout: center
---

<div class="nx-panel max-w-5xl w-full px-14 py-14">
  <div class="nx-label">Question</div>
  <h1 class="nx-title mt-8 !text-[4.2rem] !leading-[1.06] !font-semibold">
    既然已经有了 OpenClaw，
    <br />
    为什么还要再做一个
    <span class="nx-accent">NexAgent</span>？
  </h1>
</div>

---

<div class="nx-grid-2 nx-compare h-full items-center">
  <div class="nx-card pr-10">
    <div class="nx-key">OpenClaw 打开的门</div>
    <div class="mt-5 text-3xl font-semibold">Agent 已经开始像“系统”</div>
    <ul class="mt-6 space-y-3 text-xl leading-relaxed nx-muted">
      <li>会写代码</li>
      <li>会串流程</li>
      <li>会调用工具</li>
      <li>会长出意料之外的能力</li>
    </ul>
    <div class="mt-8 rounded-2xl border border-[var(--nx-line)] bg-[rgba(103,183,255,0.08)] px-4 py-3 text-base text-[#cde7ff]">
      以前更像预制软件。现在开始出现“现场组合能力”的迹象。
    </div>
  </div>
  <div class="nx-card pl-10">
    <div class="nx-key">真正的问题在后面</div>
    <div class="mt-5 text-3xl font-semibold">如果它要长期存在，该怎么活着？</div>
    <ul class="mt-6 space-y-3 text-xl leading-relaxed nx-muted">
      <li>怎么长期在线</li>
      <li>怎么进入真实聊天环境</li>
      <li>怎么组织会话和记忆</li>
      <li>学到的新东西放在哪里</li>
      <li>未来怎么稳定地继续长</li>
    </ul>
  </div>
</div>

---
layout: center
---

<div class="max-w-5xl">
  <div class="nx-label">Shift</div>
  <div class="mt-8 text-4xl nx-muted">问题已经从</div>
  <div class="mt-4 text-6xl font-semibold leading-tight">“怎么做一个 agent demo”</div>
  <div class="mt-8 text-4xl nx-muted">变成了</div>
  <div class="mt-4 text-6xl font-semibold leading-tight nx-accent">“怎么做一个长期运行的 agent 系统”</div>
</div>

---

<div class="h-full grid grid-cols-[0.9fr_1.1fr] gap-8 items-center">
  <div class="nx-panel px-8 py-8">
    <div class="nx-key">为什么要自己做</div>
    <div class="mt-6 text-3xl font-semibold leading-relaxed">
      自己做一个 agent 的意义，
      <br />
      在于真正从使用者切换到创造者。
    </div>
  </div>
  <div class="space-y-4">
    <div class="nx-card">
      <div class="text-xl font-semibold">1. 你会真正区分 prompt 问题和系统问题</div>
    </div>
    <div class="nx-card">
      <div class="text-xl font-semibold">2. 你会亲手踩到多通道、会话、记忆、调度这些坑</div>
    </div>
    <div class="nx-card">
      <div class="text-xl font-semibold">3. 你会被迫回答：这个 agent 的底层结构到底应该是什么</div>
    </div>
  </div>
</div>

---
layout: center
---

<div class="nx-panel max-w-5xl w-full px-14 py-12">
  <div class="nx-label">Position</div>
  <div class="mt-8 text-5xl leading-relaxed">
    NexAgent 的出发点，
    <span class="nx-accent">是把“养龙虾”带来的直觉继续往系统设计的方向推进一步</span>。
  </div>
</div>

---

# 继续追问

<div class="pt-2 grid grid-cols-[0.92fr_1.08fr] gap-5 items-start">
  <div class="nx-panel px-6 py-5">
    <div class="nx-key">真正把问题逼出来的</div>
    <div class="mt-4 text-[2.2rem] font-semibold leading-[1.34]">
      不是“再做一个 demo”，
      <br />
      而是下面这三个问题。
    </div>
  </div>
  <div class="space-y-[0.85rem]">
    <div class="nx-card py-4">
      <div class="text-[1.8rem] font-semibold leading-[1.25]">1. 记忆到底是什么？</div>
      <div class="mt-2 nx-muted text-[1.2rem] leading-[1.42]">有价值的往往不是“记得我是谁”，而是“记得我是怎么做事的”。</div>
    </div>
    <div class="nx-card py-4">
      <div class="text-[1.8rem] font-semibold leading-[1.25]">2. agent 的主动性从哪里来？</div>
      <div class="mt-2 nx-muted text-[1.2rem] leading-[1.42]">很多时候不是玄学规划，而是调度、定时器和后台执行结构。</div>
    </div>
    <div class="nx-card py-4">
      <div class="text-[1.8rem] font-semibold leading-[1.25]">3. 新学到的东西该放在哪里？</div>
      <div class="mt-2 nx-muted text-[1.2rem] leading-[1.42]">如果最后都堆进 prompt 或 memory，系统很快就会糊成一团。</div>
    </div>
  </div>
</div>

---
layout: center
---

<div class="w-full">
  <div class="nx-label">Part 1</div>
  <h1 class="nx-title mt-8 !text-7xl">为什么是 Elixir / OTP</h1>
</div>

---

<div class="nx-grid-2 h-full items-center">
  <div class="nx-card opacity-70">
    <div class="nx-key">如果只是单轮执行器</div>
    <ul class="mt-6 space-y-3 text-xl nx-muted">
      <li>调一次模型</li>
      <li>做几次 tool calling</li>
      <li>返回一个结果</li>
    </ul>
    <div class="mt-8 text-lg nx-muted">技术选型空间很大。</div>
  </div>
  <div class="nx-card border-[var(--nx-line-2)]">
    <div class="nx-key">如果是长期在线系统</div>
    <ul class="mt-6 space-y-3 text-xl">
      <li>多聊天通道接入</li>
      <li>多会话并行</li>
      <li>后台任务和定时任务</li>
      <li>失败恢复</li>
      <li>热更新</li>
      <li>未来可能还有自我升级</li>
    </ul>
    <div class="mt-8 text-lg text-[#cfe3ff]">运行时能力会直接变成产品能力。</div>
  </div>
</div>

---

<div class="pt-6">
  <img src="./assets/elixir-runtime.svg" class="w-full rounded-[26px] shadow-2xl" />
</div>

---
layout: center
---

<div class="w-full">
  <div class="nx-label">Part 2</div>
  <h1 class="nx-title mt-8 !text-7xl">NexAgent 里面到底有什么</h1>
</div>

---

<div class="pt-6">
  <img src="./assets/agent-system.svg" class="w-full rounded-[26px] shadow-2xl" />
</div>

---

<div class="nx-grid-2 h-full items-start">
  <div class="space-y-4">
    <div class="nx-card">
      <div class="nx-key">入口层</div>
      <div class="mt-3 text-2xl font-semibold">Gateway + Channels</div>
      <div class="mt-3 nx-muted">让 agent 真正接住持续流动的消息流。</div>
    </div>
    <div class="nx-card">
      <div class="nx-key">运行层</div>
      <div class="mt-3 text-2xl font-semibold">InboundWorker + Runner</div>
      <div class="mt-3 nx-muted">把消息、安全调度、tool calling 和 agent loop 组织成稳定过程。</div>
    </div>
  </div>
  <div class="space-y-4">
    <div class="nx-card">
      <div class="nx-key">状态与能力层</div>
      <div class="mt-3 text-[1.75rem] leading-tight font-semibold">
        SessionManager / Memory
        <br />
        Tool.Registry / Skills
      </div>
      <div class="mt-3 nx-muted">让系统具备长期会话、长期事实、方法沉淀和能力扩展。</div>
    </div>
    <div class="nx-card">
      <div class="nx-key">后台执行层</div>
      <div class="mt-3 text-2xl font-semibold">Cron / Subagent</div>
      <div class="mt-3 nx-muted">让系统获得主动执行和后台拆分执行能力。</div>
    </div>
  </div>
</div>

---

# 核心模块

<div class="grid grid-cols-3 gap-5 pt-6">
  <div class="nx-card">
    <div class="nx-key">入口</div>
    <div class="mt-3 text-2xl font-semibold">Gateway</div>
    <div class="mt-3 nx-muted">统一编排聊天入口。</div>
  </div>
  <div class="nx-card border-[var(--nx-line-2)]">
    <div class="nx-key">调度中枢</div>
    <div class="mt-3 text-2xl font-semibold">Runner</div>
    <div class="mt-3 nx-muted">上下文、LLM loop、tool calling 的中枢。</div>
  </div>
  <div class="nx-card">
    <div class="nx-key">入口到运行</div>
    <div class="mt-3 text-2xl font-semibold">InboundWorker</div>
    <div class="mt-3 nx-muted">消息路由、会话调度、排队。</div>
  </div>
  <div class="nx-card border-[var(--nx-line-2)]">
    <div class="nx-key">长期状态</div>
    <div class="mt-3 text-2xl font-semibold">Memory</div>
    <div class="mt-3 nx-muted">把用户信息和环境事实分层保存。</div>
  </div>
  <div class="nx-card">
    <div class="nx-key">能力扩展</div>
    <div class="mt-3 text-2xl font-semibold">Tool.Registry / Skills</div>
    <div class="mt-3 nx-muted">把能力和方法拆开，避免堆成一团。</div>
  </div>
  <div class="nx-card border-[var(--nx-line-2)]">
    <div class="nx-key">升级路径</div>
    <div class="mt-3 text-2xl font-semibold">CodeUpgrade / UpgradeManager</div>
    <div class="mt-3 nx-muted">给 code-level evolution 一条受控路径。</div>
  </div>
</div>

---
layout: center
---

<div class="w-full">
  <div class="nx-label">Part 3</div>
  <h1 class="nx-title mt-8 !text-7xl">进化如果不分层，系统很快就会变形</h1>
</div>

---

<div class="nx-grid-2 h-full items-center">
  <div class="nx-card border-[#4f2e3d] bg-[linear-gradient(180deg,rgba(42,18,28,.94),rgba(28,13,20,.94))]">
    <div class="nx-key !text-[#ff9ab0]">错误路径</div>
    <div class="mt-5 text-2xl font-semibold text-white">所有变化都堆在一起</div>
    <ul class="mt-6 space-y-3 text-xl text-[#f0c7d3]">
      <li>今天改一点 prompt</li>
      <li>明天记一条 memory</li>
      <li>后天补一个脚本</li>
      <li>接着再塞一个工具</li>
    </ul>
    <div class="mt-8 text-lg text-[#ffb6c6]">结果：难判断、难复用、难升级。</div>
  </div>
  <div class="nx-card border-[var(--nx-line-2)]">
    <div class="nx-key">正确路径</div>
    <div class="mt-5 text-2xl font-semibold">先决定变化该落在哪一层</div>
    <ul class="mt-6 space-y-3 text-xl">
      <li>事实进入 `USER / MEMORY`</li>
      <li>方法沉淀成 `SKILL`</li>
      <li>稳定能力升级成 `TOOL`</li>
      <li>只有最后才进入 `CODE`</li>
    </ul>
    <div class="mt-8 text-lg text-[#cfe3ff]">系统会保持可理解、可迭代。</div>
  </div>
</div>

---

<div class="pt-6">
  <img src="./assets/evolution-layers.svg" class="w-full rounded-[26px] shadow-2xl" />
</div>

---

# 分流原则

<div class="grid grid-cols-[0.75fr_1.25fr] gap-8 pt-6 items-center">
  <div class="nx-panel px-7 py-7">
    <div class="nx-key">优先级</div>
    <div class="mt-5 text-3xl font-semibold leading-relaxed">
      变化优先落在
      <span class="nx-accent">更轻、更高</span>
      的层。
    </div>
  </div>
  <div class="space-y-4">
    <div class="nx-card">
      <div class="text-xl font-semibold leading-relaxed">
        1. 能进入 <span class="nx-chip">USER / MEMORY</span>，就先不要急着写 <span class="nx-chip nx-chip-skill">SKILL</span>
      </div>
    </div>
    <div class="nx-card">
      <div class="text-xl font-semibold leading-relaxed">
        2. 能沉淀成 <span class="nx-chip nx-chip-skill">SKILL</span>，就先不要急着做 <span class="nx-chip nx-chip-tool">TOOL</span>
      </div>
    </div>
    <div class="nx-card">
      <div class="text-xl font-semibold leading-relaxed">
        3. 能做成 <span class="nx-chip nx-chip-tool">TOOL</span>，就先不要急着改 <span class="nx-chip nx-chip-code">CODE</span>
      </div>
    </div>
  </div>
</div>

---

<div class="pt-6">
  <img src="./assets/code-upgrade-flow.svg" class="w-full rounded-[26px] shadow-2xl" />
</div>

---
layout: center
---

<div class="w-full">
  <div class="nx-label">Part 4</div>
  <h1 class="nx-title mt-8 !text-7xl">为什么这件事值得做</h1>
</div>

---

# 我们真正关心的

<div class="pt-8 space-y-5">
  <div class="nx-card"><div class="text-2xl font-semibold">Agent 能不能从一个好用的 demo，变成一个长期在线的系统？</div></div>
  <div class="nx-card"><div class="text-2xl font-semibold">Agent 能不能真正进入聊天环境，成为日常工作流的一部分？</div></div>
  <div class="nx-card"><div class="text-2xl font-semibold">Agent 能不能不只记住标签和片段，而是逐渐学会方法、沉淀方法、复用方法？</div></div>
  <div class="nx-card"><div class="text-2xl font-semibold">Agent 的能力扩展，能不能有一个不会越来越乱的结构？</div></div>
</div>

---
layout: center
---

<div class="max-w-5xl">
  <div class="nx-label">Conclusion</div>
  <div class="mt-8 text-[2.2rem] leading-[1.45] text-[#b9c8e8] max-w-[68rem]">
    未来更有价值的，不是一个平均意义上“什么都会一点”的 agent。
  </div>
  <div class="mt-10 grid grid-cols-[0.95fr_1.05fr] gap-10 items-start">
    <div class="text-[4.25rem] leading-[1.02] text-[#7ca1b5] font-semibold">
      更有价值的，
      <br />
      是一个专属系统。
    </div>
    <div class="space-y-4 text-[2rem] leading-[1.45] text-[#d8e4fb]">
      <div class="nx-panel-soft px-6 py-5">它能够理解具体用户。</div>
      <div class="nx-panel-soft px-6 py-5">它服务具体工作流。</div>
      <div class="nx-panel-soft px-6 py-5">
        <span class="nx-accent">它在真实环境里持续进化。</span>
      </div>
    </div>
  </div>
</div>

---
layout: center
---

<div class="nx-panel max-w-5xl w-full px-14 py-12">
  <div class="nx-label">Closing</div>
  <h1 class="nx-title mt-8 !text-6xl">NexAgent</h1>
  <div class="mt-6 text-3xl leading-relaxed">
    它未必已经给出最终答案。
    <br />
    但它在认真把这些问题落到一个
    <span class="nx-accent">真实可运行的系统</span> 里。
  </div>
  <div class="mt-10 text-sm nx-muted">github.com/gofenix/nex-agent</div>
</div>
