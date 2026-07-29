# Design QA — 群聊底部安全区

- Source visual truth: [qa-reference-bottom-clipping.png](assets/qa-reference-bottom-clipping.png)
- Implementation screenshot: [qa-group-chat.png](assets/qa-group-chat.png)
- Combined focused comparison: [qa-bottom-comparison.png](assets/qa-bottom-comparison.png)
- Browser viewport: `1920 × 882` CSS px, device scale factor 1
- Source pixels: `816 × 394`
- Implementation pixels: `1920 × 882`; rendered phone frame `381 × 826` after responsive scale
- State: “iOS 产品小组”群聊，默认自动选择模式

## Full-view comparison evidence

The browser-rendered phone frame fits entirely inside the available viewport. Its measured bounds are `y=41` through `y=867`, within the `882px` viewport. The composer ends at the inner edge of the phone frame rather than outside it.

## Focused comparison evidence

[qa-bottom-comparison.png](assets/qa-bottom-comparison.png) places the reported bottom crop beside the revised implementation crop. The revised composer, input field, @ button, send button, rounded screen corners, and bottom bezel are all visible. No persistent control is clipped.

## Fidelity surfaces

- Fonts and typography: Existing SF/PingFang system stack, weights, wrapping, and hierarchy are unchanged.
- Spacing and layout rhythm: Added a 30px simulated iOS bottom safe area. Message-list bottom padding now follows the measured composer height and expands from `148px` to `210px` when the discussion progress panel appears.
- Colors and visual tokens: Existing accent, neutral surfaces, borders, and opacity are unchanged.
- Image quality: Existing avatar crops and source imagery are unchanged. The combined comparison is enlarged only for inspection.
- Copy and content: Existing chat content and control labels are unchanged.
- Icons: Existing Phosphor icon family and sizing are unchanged.
- Responsiveness: The `393 × 852` phone frame now scales to the available desktop stage height; the mobile full-viewport mode remains unscaled.
- Interactions: Opened the group chat, selected “@某个 Agent”, chose “技术架构师”, started and stopped “让大家讨论”, and verified composer inset updates.
- Console: No browser console errors.

## Comparison history

1. Earlier P1 finding: fixed-height phone could extend beyond a short browser viewport, making the bottom appear cut off.
   - Fix: scale the phone frame against available stage width and viewport height.
   - Post-fix evidence: phone bottom is `867px` in an `882px` viewport.
2. Earlier P1 finding: chat history reserved a fixed `112px`, while the group composer changes height.
   - Fix: measure each visible composer with `ResizeObserver` and apply its height plus `12px` as the scroll inset.
   - Post-fix evidence: default group composer uses `148px`; expanded discussion state uses `210px`.
3. Earlier P2 finding: input controls sat too close to the simulated device corner.
   - Fix: use a `30px` phone bottom safe-area token.
   - Post-fix evidence: all bottom controls and rounded corners are visible in the focused comparison.

## Follow-up polish

No remaining P0, P1, or P2 issue was found in the reported state. Desktop scaling can make the phone appear slightly smaller on short windows; this is intentional to preserve the full device frame.

## Design QA — AI 市场与设置页升级

- Source visual truth: [qa-reference-settings-profile.png](assets/qa-reference-settings-profile.png)
- AI 市场截图: [qa-market-50-agents.png](assets/qa-market-50-agents.png)
- 设置页截图: [qa-settings-profile.png](assets/qa-settings-profile.png)
- Browser viewport: `1041 × 806` CSS px
- Rendered phone frame: `346 × 750` CSS px
- Measured phone bounds: `y=28` through `y=778`

### Full-view comparison evidence

新版设置页保留原参考图的 iOS 分组列表结构，同时把头部资料区扩展为身份、同步状态和三项统计组成的完整资料卡。AI 市场以 10 位专家为首屏，继续滚动分批加载至 50 位；筛选、搜索和详情页使用同一份专家数据。

### Fidelity surfaces

- Fonts and typography: 使用 SF/PingFang 系统字体，资料标题、辅助文字和统计数字形成清晰的三级层级。
- Spacing and layout rhythm: 资料卡实测高度 `144px`；设置列表可独立滚动，末组底部 `y=679`，固定标签栏顶部 `y=700`，没有遮挡。
- Colors and visual tokens: 沿用单一靛蓝强调色、浅灰页面底色和白色分组卡片，不引入微信品牌色或素材。
- Image quality: 用户头像与市场专家头像保持清晰裁切；加载失败时提供文字头像回退。
- Copy and content: 资料卡展示 Halo ID、使用偏好、iCloud 同步、Agent 数、本月用量和共享记忆数。
- Icons: 设置页 12 个功能入口全部使用同一套 Phosphor 矢量图标，无文字占位图标。
- Responsiveness: 修复短视口中变换前尺寸参与网格对齐的问题；手机从原来的 `y=79–829` 调整为 `y=28–778`，完整落在 806px 视口内。
- Interactions: 验证搜索“合同”得到 3 位匹配专家；“法律财税”筛选得到 8 位专家；连续滚动从 `10 / 50` 加载到 `50 / 50`；专家卡可进入对应详情。
- Console: 浏览器控制台无错误。

### Comparison history

1. Earlier P1 finding: 手机虽被缩放，但 CSS Grid 仍以缩放前的 `852px` 高度进行安全对齐，短视口中底部越界。
   - Fix: 舞台改为顶部对齐，手机缩放原点改为顶部居中，并按缩放后的实际高度计算顶部留白。
   - Post-fix evidence: 手机底部为 `778px`，距视口底部保留 `28px`。
2. Earlier P2 finding: 设置页个人资料信息量不足，功能入口使用文字图形。
   - Fix: 增加资料摘要、同步状态和统计区；全部入口替换为统一 SVG 图标字体。
   - Post-fix evidence: 12 个入口图标全部存在，资料卡关键字段完整显示。
3. Earlier P2 finding: AI 市场样本过少，无法验证真实发现和浏览体验。
   - Fix: 增加 50 位跨 6 类场景的专家、搜索、分类、10 位一批的增量加载和数据绑定详情。
   - Post-fix evidence: 默认 `10 / 50`，最终 `50 / 50`，详情页名称与模型信息随所选专家变化。

No remaining P0, P1, or P2 issue was found in the tested market and settings states.

## Design QA — 全会话 Mock 数据

- Implementation screenshot: [qa-rich-conversations.png](assets/qa-rich-conversations.png)
- Browser viewport: `1920 × 882` CSS px
- Tested phone bounds after page navigation: `y=28` through `y=854`
- Conversation list: 12 rows, including 3 groups and 9 Agent/task/system conversations

### Interaction evidence

- Opened all 9 data-driven conversations; each displayed a different title, message count and format combination.
- Opened all 3 groups; product, research and content groups displayed independent histories and no call buttons.
- Verified Agent conversations expose call controls while task and system conversations hide them.
- Sent “把结论压成三条” in the general assistant conversation; the message and list preview both updated to the new text and “刚刚”.
- Continued the failed spreadsheet upload from 74%, stopped the research task and confirmed the calendar event.
- Opened both “数据与权限” and “模型与用量” sheets from the system conversation.
- All 9 shared conversations measured `scrollWidth = clientWidth = 375px`; no horizontal overflow was found.
- Browser console contained no errors.

### Format coverage

- Text, long text and quoted replies.
- Single image and image gallery.
- PDF, DOCX, XLSX and ZIP files.
- Voice message and transcript.
- Web source and citation cards.
- Data tables, metrics and bar charts.
- Progress, checklist and calendar cards.
- Risk, conflict, failure, permission, quota, degradation and recovery states.

### Layout correction

The device frame originally moved from `y=28` to `y=2` after switching pages because transformed device dimensions interacted with an oversized Grid/Flex layout item. The stage now positions the single phone frame absolutely from its 28px safe inset while preserving top-centered scaling. Post-fix navigation keeps the phone at `y=28–854`.

No remaining P0, P1, or P2 issue was found in the tested conversation states.

## Design QA — 标题与通话入口

- Source reports: `codex-clipboard-fae5f3df-6067-4c69-9d73-479e606e08d7.png`, `codex-clipboard-8edc2716-4e51-4c5f-bb19-6a6aa1dbdf8c.png`
- Implementation screenshot: [qa-call-menu.png](assets/qa-call-menu.png)
- Browser viewport: `1920 × 882` CSS px

### Findings and fixes

- Compact navigation used `space-between`; titles moved when the right side contained two call buttons, one status or no control.
- Compact titles now use absolute 50% positioning within the phone navbar. Information monitoring, translation and contract review all measured a `0px` center delta.
- One-to-one voice and video controls were generated in the top navbar. They are now removed from the navbar and generated inside the bottom “＋” sheet according to the current Agent capabilities.
- Translation expert showed one voice and one video action in “发送与通话”; deep research showed neither action.
- The call sheet uses the same Phosphor icon family as the rest of the prototype.
- Phone bounds remained `y=28–854`; browser console contained no errors.

No remaining P0, P1, or P2 issue was found in the reported states.

final result: passed

## Design QA — 聊天详情、专家资料与多 Provider

日期：2026-07-28

- 自动化契约测试：39 passed，0 failed。
- 单聊详情补齐专家入口、添加群聊、聊天记录分类、免打扰、置顶、重要提醒、背景、导出、清空与反馈。
- 群资料补齐成员资料跳转、群记录分类、通用会话设置、背景、导出以及清空/删除的不同确认文案。
- 专家资料补齐 Provider / 模型标签、专家数据、最近活动、圈层筛选、发布权限和更多操作。
- 多 Provider 页面支持 ToAPIs、DeepSeek、OpenAI、Anthropic Claude、Google Gemini、自定义 OpenAI-compatible、本地模型、豆包端到端语音与 Vidu；多个 Provider 可并存。
- 默认文字、图片、视频、Router 以及单 Agent 覆盖均显示 `providerId + modelId`；群聊 Mock 验证不同 Agent 可使用不同 Provider。
- Google Gemini 展示连接异常，本地模型展示离线/可无 Key，未配置 Provider 保持独立状态。
- 浏览器点击复测发现并修复默认模型选择把对象误传为 `providerId` 的问题；修复后选择 OpenAI 更新为 `OpenAI / gpt-5`。
- 手机容器与模型服务滚动面横向溢出均为 `0px`；浏览器控制台 0 warning、0 error。
- 对照证据：[参考与实现对照](assets/chat-details-expert-profile-2026-07-28/08-reference-comparison.png)、[聊天详情](assets/chat-details-expert-profile-2026-07-28/01-chat-details.png)、[专家资料](assets/chat-details-expert-profile-2026-07-28/03-expert-profile.png)、[模型服务](assets/chat-details-expert-profile-2026-07-28/05-model-providers.png)、[Provider 异常态](assets/chat-details-expert-profile-2026-07-28/06-provider-error.png)。

final result: passed

## Design QA — 专家团与圈层

日期：2026-07-28

- 自动化契约测试：34 passed，0 failed。
- 四个主入口已统一为“对话、专家团、圈层、设置”，桌面导航与 iOS 底栏文案一致。
- 圈层取消封面、压头像、点赞评论条和内容分类，改为独立白色动态卡；5 条 Mock 覆盖主动分享、对话成果、定时任务、监控变化和任务失败。
- 圈层严格按发布时间倒序表达，每条动态展示专家、模型、来源类型、生成时间和可继续操作。
- 三图卡进入统一全屏预览后显示 `1 / 3`，支持上一张、下一张；文件和网页继续复用统一预览。
- 专家资料页提供“允许发布到圈层”开关；关闭与恢复均有明确反馈。
- 圈层发布管理完成“允许 → 确认禁止 → 已禁止 → 恢复允许”闭环，并明确禁发不停止对话、任务、定时任务或监控。
- 圈层页面与滚动容器的横向溢出均为 `0px`；浏览器控制台 0 warning、0 error。
- 视觉证据：[圈层信息流](assets/expert-team-circle-2026-07-28/01-circle-feed.png)、[专家资料与发布开关](assets/expert-team-circle-2026-07-28/02-expert-profile.png)。

final result: passed

## Design QA — 全界面可点击性与富媒体预览

日期：2026-07-28

- 自动化契约测试：31 passed，0 failed。
- 浏览器回归范围：20 个页面、图片/多图/文件/网页三类预览、通讯录详情、群资料、共享上下文、语音消息、表格与图表卡片、AI 市场。
- 图片消息、群聊四图、朋友圈三图统一进入全屏预览；多图支持前后切换和张数提示。
- 文件与网页卡片使用同一个预览层，朋友圈中的图片、成果文件和正文详情互不抢占点击事件。
- 通讯录 9 个 Agent 均可进入资料页；资料页名称、模型、头像和描述随所选 Agent 更新。
- 群目标、主持 Agent、共享文件、资料文件夹和私有记忆入口均有详情、选择、预览或 Toast 反馈。
- 语音消息、数据表和图表改为语义化按钮；语音具有播放/暂停状态，数据卡可展开详情。
- 语音与视频通话控制改为语义化按钮，并提供清晰的选中状态和操作反馈。
- AI 市场列表和详情统一显示 BYOK：使用用户自己的 API Key，费用由模型服务商直接结算。
- 所有已检查页面横向溢出为 0；紧凑导航标题中心偏差为 0；浏览器控制台 0 warning、0 error。
- 最终证据位于 `docs/06-quality/assets/ui-audit-2026-07-28/23-final-gallery-preview.png.png` 至 `28-final-rich-card.png.png`。

final result: passed

## Design QA — 无账号、本地优先与 BYOK

日期：2026-07-28

- 自动化契约测试：26 passed，0 failed。
- 浏览器检查：设置、模型服务、Provider 详情、本地数据与备份。
- 设置页显示“无账号 · 数据由你掌控”，不再包含账户、退出、验证码、密码或充值入口。
- 模型服务展示 6 个 Provider 模板；OpenAI-compatible 连接测试返回成功状态。
- Provider 详情明确 API Key 只保存在本机 Keychain。
- 本地数据页提供导出、导入、缓存清理和清除本机数据，并说明导出包不包含 API Key。
- 三个页面未出现横向溢出、粗浏览器滚动条或底部裁切。
- 浏览器控制台：0 warning，0 error。

final result: passed

## Design QA — 退出登录点击修复

> 历史记录：该流程已被 2026-07-28 的无账号、本地优先方案移除。

- Root cause: 高层级 Toast 即使透明仍参与点击命中，覆盖了退出确认弹层的主按钮。
- Fix: Toast 设置 `pointer-events: none`，保留视觉反馈但不再阻挡下方控件。
- Browser verification: 从设置页和账户中心分别打开退出确认，鼠标点击「退出登录」后均进入登录页，弹层关闭。
- Hit-test verification: 修复前按钮中心命中 `#toast`；修复后命中退出按钮自身。
- Browser console: 0 warning，0 error。

final result: passed

## Design QA — 账户、认证与 Token 充值

> 历史记录：该整组页面已被无账号、BYOK、本地数据和自托管 Gateway 页面替代，不再属于当前原型。

- Browser viewport: `1900 × 850` CSS px
- Automated contract tests: 24 passed, 0 failed
- Pages checked: 设置、账户中心、切换账号、修改密码、Token 中心、充值确认、充值结果、密码登录、验证码登录、忘记密码

### Interaction evidence

- 设置页展示账户安全、Token 充值和独立退出登录入口。
- Token 中心显示 128,600 初始余额、3 个套餐和 4 类交易；选择 260K 套餐并用支付宝模拟支付后，余额更新为 388,600。
- 充值成功与失败结果均可返回余额页或重新支付。
- 账号列表展示 3 个 mock 账号；切换到「产品研究」后设置资料同步更新并返回对话页。
- 修改密码的不一致状态显示字段级错误；合法密码提交后返回账户中心。
- 退出登录包含取消与确认；确认后进入不含四栏主导航的登录页。
- 密码登录的空账号和弱密码会显示字段错误；合法输入后回到对话页。
- 验证码登录完成联系方式、发送、六位输入和登录闭环。
- 忘记密码完成联系方式、验证码和新密码三步，最终返回登录页。

### Layout evidence

- 登录页和 Token 中心均测得 `scrollWidth - clientWidth = 0`。
- Token 中心、充值确认、充值结果、切换账号和设置页标题保持居中。
- 认证页不渲染底部四栏主导航。
- 页面内容未被圆角、底部安全区或固定按钮裁切。
- 浏览器控制台无 warning 或 error。

final result: passed
