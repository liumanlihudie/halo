# 圈层（原「AI 朋友圈」）落地实现计划

日期：2026-07-30
依据：`docs/04-feature-specs/05-expert-team-circle-design.md`（数据模型、更多菜单、
视觉与验收清单以该文档为准）、`docs/01-product/02-product-design.md` §6 / §7
前一份计划：`docs/05-implementation-plans/04-expert-team-circle-plan.md` ——
那份只做 HTML 原型，已完成；本计划是把它落到 Flutter 正式客户端。

现状：`apps/mobile/lib/features/circle/circle_page.dart`（362 行）与
`moment_detail_page.dart`（143 行）是纯静态原型，内容来自
`HaloFixtures.circlePosts`。没有存储、没有发布通路、没有 `canPublishToCircle`
校验、更多菜单 6 项一项都没有。**这条链路目前零真实代码。**

## 0.1 定位（2026-07-30 产品决策，覆盖规格原文）

圈层的内容**只有两个来源**：

1. **对话过程中形成的** —— 结论、成果、失败，由用户手动发布或由运行结果自动落。
2. **编排的定时任务** —— 复用现有 `OrchestrationKernel`，在**打开 App 时补跑到期任务**。

不做「专家在你不看手机时自己活动」。理由是本地架构下它根本做不到：
`Info.plist` 当前没有声明任何 `UIBackgroundModes` / `BGTaskSchedulerPermittedIdentifiers`，
App 挂起后 Dart 一行不跑；即便声明了，`BGAppRefreshTask` 只有约 30 秒预算
（带工具调用的模型请求很容易超），`BGProcessingTask` 通常要充电+空闲才轮到，
且用户在多任务界面上划杀掉后系统不再调度。
（顺带记录：Keychain 用的是 `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`，
开机解锁一次后后台锁屏也能读到 Key，**凭证不是障碍，"能不能醒"才是**。）

因此圈层是**结果沉淀区**，不是实时动态流。文案不得暗示实时性或准点。

## 0. 三条硬约束

1. **业务层校验，不能靠 UI。** 规格 §6 原文：「正式客户端必须在创建 `CirclePost`
   前检查 `canPublishToCircle`。UI 隐藏或禁用开关不能代替业务层校验。」
   所以权限判断放在 store 的写入路径里，UI 只是它的显示。
2. **圈层内容脱离了对话上下文。** 单独看到一条动态时用户没有提问上下文可参照，
   比聊天气泡更容易被当成事实。必须复用现有结构化投影闸门：
   `claimType=advice / verified=false` 钉死、常驻「未核验」、执行类信封拒绝。
   不因为「只是条动态」而放松。
3. **发布必须幂等。** 一次运行重试两次不能出两条动态。沿用聊天 outbox 纪律：
   幂等键 `(sourceId, sourceType)` 建唯一索引兜底。

## 0.5 与已完成实现的冲突（规格按现状改，不是反过来）

规格写于原型阶段，下面几处与已落地的代码冲突，**以现状为准**，规格待回写：

1. **`agentId` 用哪个 ID。** 规格只写 `agentId`，但代码里专家有两个身份：
   `profileId`（市场/资料页，如 `product`）和 `canonicalExpertId`
   （可执行身份，如 `product-manager`），聊天全链路用后者。圈层若用 profileId，
   会出现「资料页关了发布但业务层没拦住」的静默失效。
   **决定：`CirclePost.agentId` 与 `AgentCircleSettings.agentId` 一律用
   `canonicalExpertId`**，资料页开关自己做一次映射。
2. **`保存为记忆` 从菜单里去掉**（规格 §4.4 列了）。记忆功能整体未建，
   现在放上去只能是点了没反应的空壳。**宁可少一项。**
3. **`转发给其他专家` 暂缓**（规格 §4.4 列了）。它需要「把一段内容作为输入投给
   另一专家」的通路，与 Agent 联网搜索的工具执行环路是同一块地基，跟那个一起做。
4. **必须并进本轮刚做完的本地数据页**（规格写于该页存在之前）：
   - `清除本机数据` 现在只删聊天消息。圈层落地后**必须一并清除**，
     否则这个按钮就在骗人；
   - 导出数据包要带上圈层动态（同样不含任何凭证）；
   - 本地数据页的计数要把动态数算进去。
   这三项写进 P1 的验收，不能留到以后。
5. **首次启动是空的。** 换成真实存储后圈层一开始没有任何内容——这是诚实的结果，
   不要用 `HaloFixtures.circlePosts` 兜底假装有内容。如果你希望新用户第一眼有东西看，
   那是「新手引导」，应该显式标注为示例，而不是伪装成专家真的发过。

## 1. 分期

| 期 | 内容 | 依赖 | 现在能做 |
| --- | --- | --- | --- |
| P1 | 存储 + 真实渲染 + 更多菜单 + 发布权限 | 无 | ✅ |
| P2 | 对话结果发布（手动 + 失败自动） | P1 | ✅ |
| P3 | 专家主动发布（`spontaneous`，仍由一次真实对话运行产生） | P2 | ✅ 需对抗测试 |
| P4 | `schedule` 定时任务（前台补跑） | P1 | ✅ 可与 P2 并行 |

`monitor` 来源暂不单列：在前台补跑模型下它就是一种 `schedule` 任务，
等真加了后台窗口再拆。

## 2. P1 — 地基

### T1 存储（严格按规格 §6 的字段名）

- New: `apps/mobile/lib/features/circle/circle_post_store.dart`
  - **独立 drift 库 `halo_circle.sqlite`**，不动 `halo_single_chat.sqlite`：
    后者 schema v1 无升级路径，加表会让所有已装 App 开不了（本轮已踩过一次，
    见 `supersededSingleChatExpertBindings` 那次 P0）。
  - `circle_posts`：`id` PK、**`author_type`(`expert|group`)**、
    **`author_id`**（专家用 canonicalExpertId，群用 groupId）、
    **`member_agent_ids` JSON**（群动态的成员头像排，按发言顺序；专家动态为空）、
    `source_type`(`conversation|task|schedule|monitor|spontaneous`)、
    `source_id` nullable、`source_label`、`title` nullable、`body`、
    `content_type`(`text|image|gallery|file|video|data|status`)、`assets` JSON、
    `created_at_epoch_ms`、`state`(`published|deleted`)、
    `origin_key` **UNIQUE**（幂等键）。

    > **为什么不是规格里的单个 `agent_id`**：群聊总结由独立的总结身份产出
    > （`production_group_chat_port.dart:70`，只用全局默认模型、不吃专家 override），
    > 它不属于任何单个专家。硬塞进某个成员名下就是伪造署名。所以作者拆成
    > `author_type` + `author_id`，成员另存一列只用于头像展示。
  - `agent_circle_settings`：`agent_id` PK、`can_publish_to_circle`。
    **缺行 = 允许**（规格默认 true）。
  - `group_circle_settings`：`group_id` PK、`can_publish_to_circle`。
    对应 `group_info_page.dart:61` 那个「讨论总结发布到圈层」开关
    （**现在是 `onChanged: null` 的死开关**，本期接真）。
  - 写入 API `publish(...)` 内部先查权限，被禁止时返回明确的拒绝结果而不是
    静默丢弃。**群动态查群开关，专家动态查专家开关**——群总结不是成员发的，
    不该被某个成员的禁令连带拦掉；反之禁了群也不影响成员各自发。
  - `state=deleted` 是软删：规格 §4.4 要求禁止发布后「当前动态保留」，
    删除是独立动作，两者不能互相牵连。
- Test（真实 SQLite）：时间倒序；幂等键冲突只留一条；权限缺省允许；
  **禁止发布后历史动态仍可读**；被禁专家的新发布被拒。

### T2 页面接真数据 + 群动态卡片

- Modify: `circle_page.dart` → `CircleController`(ChangeNotifier) 驱动；
  真空态（「还没有动态」），不是假数据兜底。
- Modify: `moment_detail_page.dart` 同上。
- Test：空 / 有数据 / 读取失败三态；**断言 `HaloFixtures.circlePosts` 不再出现**。

#### 群动态卡片结构（2026-07-30 产品决策）

```text
[群头像] iOS 产品小组                       10:36
         群聊总结 · 未核验
         ─────────────────────────────
         本轮结论：先把 MVP 收敛到三条……
         ─────────────────────────────
         [头][头][头][头]  4 位专家参与       进入群聊 ›
```

- **署名是群**（`author_type=group`），不是某个专家。
- **成员头像排**：按参与顺序展示 `member_agent_ids`，超出 N 个折叠成 `+K`。
- 头像排是「谁参与了」的信息，不是点赞位——**不做点赞评论条**。

#### 导航（照微信的通用范式，逐条钉死）

| 点哪里 | 去哪里 |
| --- | --- |
| 群头像 / 群名 | 进该群聊 `/group/:groupId` |
| 成员头像排里的某个头像 | 该专家资料页 `/expert/:profileId` |
| 「进入群聊 ›」 | 同群头像 |
| 专家动态的头像 / 名字 | 该专家资料页 |
| 卡片正文 | 动态详情 `/circle/:postId` |

- 存的是 `canonicalExpertId`，跳资料页要**映射回 `profileId`**
  （见 §0.5 第 1 条）；映射不到时头像不可点，**不能跳到空白页**。
- Test：每一行都有一个点击断言；映射缺失时不可点。

#### 视觉界线（规格 §2.2 保留，其余照微信）

**交互范式照做**（头像排、点头像进资料、点卡片进群、时间右对齐）。
**但不碰品牌资产**：不用微信名称与「朋友圈」称谓、不用其绿色品牌色、不用其官方图标、
不做大封面 + 压边头像的逐像素复刻、不做点赞评论条。
理由是这几项是可识别的品牌与版面特征，与「模仿交互习惯」是两件事。

### T3 更多菜单（规格 §4.4 六项）

- ✅ 继续和该专家对话 → 带引用打开该专家对话
- ✅ 查看来源 → 跳 `source_id` 指向的对话/文件
- ✅ 删除这条动态 → 软删 + 确认
- ✅ 不让该专家发圈层 → 确认面板含专家名 + 明确写「不会停止任务，只禁止新动态」
  → 更新 `canPublishToCircle` → 当前动态保留 → Toast「已禁止该专家发布到圈层」
- ⏸ 转发给其他专家 → 需要「把一段内容作为输入投给另一专家」的通路，
  与联网搜索的工具环路是同一块地基，跟那个一起做
- ⛔ 保存为记忆 → 记忆功能整体未建，现在做只能是空壳；**不做，菜单里也不显示**
  （宁可少一项，不要放一个点了没反应的项）

### T4 两处开关入口

- 专家资料页：重新开启 / 关闭该专家的圈层发布（规格 §7 验收项）。
- 设置页：「圈层发布」入口 → 按专家列出开关总览。
- Test：两处改同一份状态；关掉后 store 层拒绝发布；对话与任务入口不受影响。

### T5 并进本地数据页（见 §0.5 第 4 条）

- Modify: `local_data_maintenance.dart` 的 `SingleChatHistoryMaintenance` 之外
  再加一个圈层维护端口，`eraseLocalData` 同时清两处、`exportBundle` 同时导出两处、
  `loadSnapshot` 的计数把动态算进去。
- Test：清除后动态数归零且导出包不再含动态；导出包全文扫描仍不含任何凭证字样。

## 3. P2 — 从对话结果发布

### 群聊总结（第一条真实通路，最省事）

群聊侧的总结编排**已经是真的**，不用新建：
`ConversationStage.summarizing` → `BasicDurableRunner._invokeSummary` →
`AgentRuntime.summarize(DiscussionSummaryRequest)`（带 idempotencyKey、
走 `ExternalCallKind.summarize`、进 `SqliteModelCallJournal` 计费账本）→
发 `OrchestrationEventType.summaryCompleted`（`dedupeKey: 'summary-completed'`）。

- 在 `summaryCompleted` 事件上挂发布订阅者，`author_type=group`，
  幂等键直接用现成的 `(runId, 'summary-completed')`——**不需要新造幂等机制**。
- `member_agent_ids` 取本轮实际发言的成员，按发言顺序。
- 接活 `group_info_page.dart` 那两个死开关：「每次讨论自动总结」控制要不要跑
  总结阶段，「讨论总结发布到圈层」控制跑完要不要发。
- Test：关掉发布开关后 `summaryCompleted` 不产生动态但总结仍在群里；
  同一 runId 重放两次只出一条。

### 单聊（不额外花钱）

- 长按消息菜单（另一会话已做的 `MessageActionsService`）加「发布到圈层」，
  `sourceType=conversation`、`author_type=expert`，
  幂等键 `(commandId, 'conversation')`。
- **发的是那条答案本身，不新增摘要调用。** 单聊是一问一答，用户刚看完这条回答，
  再花一次模型调用把它压短收益很低。真要「总结后发布」应当是用户显式选择的
  另一个动作，而不是每条都自动摘要——那是一笔隐形的持续开销。
- 运行失败落一条 `content_type=status` 动态 + 重试入口，
  幂等键 `(commandId, 'failure')`；**只发用户可见的失败**，
  内部重试噪音不倒进圈层。
- 安全：正文只能取已过 `validateAndProject` 的 `Answer` 字段，不是原始模型输出；
  附件只存 `AssetReference`，不复制原始私密文件（产品 §6.3
  「原始私密文件不直接展示」）。

## 4. P3 — 专家主动发布（`spontaneous`）

- 专家输出信封增加可选 `CirclePost` 段：`{contentType, title?, body, uncertainty}`。
- 闸门不变：非 structural profile 一律拒；`verified=false` 钉死；UI「未核验」。
- 每轮最多一条，且必须由本轮真实运行产生——禁止模型要求补发历史或代发他人。
- Test（对抗样例）：正文伪造 `verified=true`、一轮要求发多条、要求以别的
  `agentId` 发布、要求发已被禁止的专家名下——**全部必须被拒**。

## 5. P4 — 编排的定时任务（前台补跑）

**不新建执行引擎。** 到期的任务就是走现有 `OrchestrationKernel.startRun`
的一次普通编排运行，产物落成 `sourceType=schedule` 的动态。要新建的只有
「什么时候该跑」这一张表和补跑闸门。

### T6 任务定义与到期判断

- New: `circle_scheduled_jobs` 表：`job_id` PK、`agent_id`(canonical)、
  `prompt`、`cadence`(daily/weekly/…)、`next_due_epoch_ms`、
  `last_run_epoch_ms` nullable、`enabled`。
- 进入前台时检查到期任务，逐个走编排跑，产物发圈层。

### T7 补跑闸门（这里最容易出事，全是花钱的操作）

1. **漏了 N 期只跑一次。** 三天没开 App 不能跑三次日报——那是三倍账单，
   且内容高度重复。跑一次，动态如实标注「补跑 · 覆盖 X 至 Y · 实际执行时间 Z」。
2. **幂等键 `(job_id, period_key)`**，唯一索引兜底：同一天开两次 App 不重复跑。
3. **计费闸门复用现有的** `SqliteModelCallJournal` / billing fence，
   补跑不能绕过任何一道额度检查。
4. **首次安装不自动跑**：用户没见过这个任务，不能一打开 App 就替他花钱。
5. **失败不静默**：补跑失败落一条 `status` 动态 + 重试入口，与 P2 的失败通路同一条。
6. **不阻塞启动**：补跑在后台 isolate/异步跑，UI 立刻可用，不能让人开 App 等模型。

### T8 文案

任何位置不得出现「每天 8:00 自动为你复盘」这类承诺。写「打开 App 时补跑」。

### 以后要不要加 BGTaskScheduler

可以叠加，但只让后台窗口做**便宜的活**（例如监控类只发一个 HTTP 请求看目标有没有变，
30 秒够），发现变化先落一条「检测到变化」的动态，**需要模型总结的部分留到前台**。
这样不会把 30 秒窗口浪费在必然超时的模型调用上。**本期不做。**

## 6. 并行与分工

- P1 的 T1/T2/T4 彼此独立，可三个子代理并行；T3 依赖 T1。
- P2、P3 串行在 P1 之后。
- 与另一会话无重叠：圈层只碰 `features/circle/**`、`expert_profile_page.dart`
  一个开关、`settings_page.dart` 一个入口；语音 / 通话在 `single_chat_*` 与
  media，互不相干。
- 体量参考：P1+P2 ≈ 本轮「本地数据页 + Face ID」两批之和。
