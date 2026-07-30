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
| P3 | 专家主动发布（`spontaneous`） | P2 | ✅ 需对抗测试 |
| P4 | `schedule` / `monitor` 两类来源 | P3 + §5 决策 | ⛔ 卡决策 |

## 2. P1 — 地基

### T1 存储（严格按规格 §6 的字段名）

- New: `apps/mobile/lib/features/circle/circle_post_store.dart`
  - **独立 drift 库 `halo_circle.sqlite`**，不动 `halo_single_chat.sqlite`：
    后者 schema v1 无升级路径，加表会让所有已装 App 开不了（本轮已踩过一次，
    见 `supersededSingleChatExpertBindings` 那次 P0）。
  - `circle_posts`：`id` PK、`agent_id`、`source_type`
    (`conversation|task|schedule|monitor|spontaneous`)、`source_id` nullable、
    `source_label`、`title` nullable、`body`、`content_type`
    (`text|image|gallery|file|video|data|status`)、`assets` JSON、
    `created_at_epoch_ms`、`state`(`published|deleted`)、
    `origin_key` **UNIQUE**（幂等键）。
  - `agent_circle_settings`：`agent_id` PK、`can_publish_to_circle`。
    **缺行 = 允许**（规格默认 true）。
  - 写入 API `publish(...)` 内部先查 `canPublishToCircle`，被禁止时返回明确的
    拒绝结果而不是静默丢弃。
  - `state=deleted` 是软删：规格 §4.4 要求禁止发布后「当前动态保留」，
    删除是独立动作，两者不能互相牵连。
- Test（真实 SQLite）：时间倒序；幂等键冲突只留一条；权限缺省允许；
  **禁止发布后历史动态仍可读**；被禁专家的新发布被拒。

### T2 页面接真数据

- Modify: `circle_page.dart` → `CircleController`(ChangeNotifier) 驱动；
  真空态（「还没有动态」），不是假数据兜底。
- Modify: `moment_detail_page.dart` 同上。
- 视觉不动（规格 §5 已验收）：不要封面、不要压边头像、不要点赞评论条、
  卡片间保持明确间距、不用九宫格。
- Test：空 / 有数据 / 读取失败三态；**断言 `HaloFixtures.circlePosts` 不再出现**。

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

- 长按消息菜单（另一会话已做的 `MessageActionsService`）加「发布到圈层」，
  `sourceType=conversation`，幂等键 `(commandId, 'conversation')`。
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

## 5. P4 — 需要你决定的一件事

规格里 `sourceType` 含 `schedule` 和 `monitor`，产品文档要求「定时任务、每日复盘、
周期报告、监控变化」。这些要在用户不开 App 时发生，而 iOS 只提供
`BGTaskScheduler` 的**尽力而为**调度：系统按用户使用习惯、电量、网络自行决定
何时执行，可能延迟数小时甚至不执行，被用户在多任务界面上划杀后不再调度。
纯本地方案下「每天早上 8 点的复盘」**做不到准点**。三个选项：

- **A. 前台补跑**：打开 App 时发现「上次执行是 3 天前」，补跑并如实标注
  「补跑 · 实际执行时间 X」。不骗人，但不是真定时。
- **B. A + BGTaskScheduler**：系统愿意时后台跑，提高及时性，仍不保证准点。
- **C. 服务端 + 推送**：真准点，但需要账号体系和常驻服务，
  与「无账号、数据在本机」的定位直接冲突。

**建议 A+B**，文案上永远不承诺准点。除非你要做云版本，否则不建议 C。

## 6. 并行与分工

- P1 的 T1/T2/T4 彼此独立，可三个子代理并行；T3 依赖 T1。
- P2、P3 串行在 P1 之后。
- 与另一会话无重叠：圈层只碰 `features/circle/**`、`expert_profile_page.dart`
  一个开关、`settings_page.dart` 一个入口；语音 / 通话在 `single_chat_*` 与
  media，互不相干。
- 体量参考：P1+P2 ≈ 本轮「本地数据页 + Face ID」两批之和。
