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
- AI 市场截图: `/Users/cofe/office Lady/IOS-IM/qa-market-50-agents.png`
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

## Design QA — 退出登录点击修复

- Root cause: 高层级 Toast 即使透明仍参与点击命中，覆盖了退出确认弹层的主按钮。
- Fix: Toast 设置 `pointer-events: none`，保留视觉反馈但不再阻挡下方控件。
- Browser verification: 从设置页和账户中心分别打开退出确认，鼠标点击「退出登录」后均进入登录页，弹层关闭。
- Hit-test verification: 修复前按钮中心命中 `#toast`；修复后命中退出按钮自身。
- Browser console: 0 warning，0 error。

final result: passed

## Design QA — 账户、认证与 Token 充值

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
