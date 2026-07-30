# 语音消息设计（非端到端）

日期：2026-07-30
状态：设计定稿，待实现
决策人：产品负责人（2026-07-30 口头确认）

## 1. 产品定位与非目标

语音消息 = **像和真人互发 60 秒语音一样**与专家异步对话：

- 用户按住说话 → 专家用语音气泡回复；
- 双方气泡都可播放、可展开文字稿（微信「转文字」习惯）；
- 天然异步，对 STT + 推理 + TTS 的叠加延迟不敏感。

**非目标**：实时全双工语音通话。那是「语音通话」按钮的领域（端到端语音模型
+ WebSocket/WebRTC + 自托管 Gateway 签发临时凭证，见
`02-architecture/02` 与 `04-local-first-open-source-architecture.md`），
与本设计互不阻塞，本文档不覆盖。

## 2. 核心架构决策：语音只是两端的皮

```
按住说话 → 录音(m4a, ≤60s) → 存 attachments/<uuid>.m4a
  → ASR 转写 → 文字作为用户消息进入【现有专家管线，零改动】
      （模型路由 override??global、输出信封校验、Answer 自然回答、未核验框架）
  → Answer 文字 → TTS 合成 → 存 attachments/<uuid>.m4a
  → 专家语音气泡（时长 + 播放 + 文字稿 + 未核验标识）
```

这样设计的理由：

1. 文字管线承载全部安全与路由保证，**换媒介不换骨架**；
2. 转写文字与合成音频都持久化，历史可检索、可审计；
3. 「未核验」标识保留在气泡上——语音播出来的话无法带角标，
   文字稿与角标共同承担披露职责，安全框架不因媒介消失。

## 3. Provider 现状（实证，2026-07-30）

产品决策是**优先走 ToAPIs 聚合**（Key 已配置，不新增凭证）。实测：

- `https://docs.toapis.com/llms.txt` 全量索引：账户 / Chat（Chat Completions、
  Responses、Anthropic Messages）/ 图片生成 / 视频生成 / 上传 / 异步任务 /
  Webhook。**没有任何音频推理端点**（无 TTS、无 ASR、无 realtime）。
- `list-models` 文档保留 `type=audio` 筛选值，说明目录侧已为音频模型预留；
  但没有可调用的推理接口。
- `openapi.json` 为模板占位符，不构成额外证据。

结论：**「ToAPIs 聚合的豆包双工 TTS」这条路今天还不存在**。设计必须
把语音供给做成可插拔座位，ToAPIs 音频端点上线即可接入，同时提供
不阻塞整条功能的过渡层。

## 4. 语音供给分层（Speech Provider Seam）

`lib/model_runtime/` 新增两个窄接口，与 `ChatModelRuntime` 同级：

```dart
abstract interface class SpeechTranscriber {
  /// 音频文件 → 文字。失败抛 ModelRuntimeException（安全消息，不泄上游正文）。
  Future<SpeechTranscript> transcribe(SpeechTranscriptionRequest request);
}

abstract interface class SpeechSynthesizer {
  /// 文字 → 音频文件（写入调用方给定的目标路径）。
  Future<SpeechAudio> synthesize(SpeechSynthesisRequest request);
}
```

实现层级（按优先级解析，配置于设置页「语音」分组）：

| 层 | 实现 | 状态 | 说明 |
|---|---|---|---|
| A | **ToAPIs 音频端点** | 待其上线 | 首选。目录里 `type=audio` 模型 + 端点白名单新增 `/audio/...` 路径后接入；沿用现有 Key、计费围栏、错误脱敏 |
| B | 豆包火山引擎直连 | 可选 | 需新增 Provider（独立 Key + 端点白名单 + 适配器），产品已表态暂不走，保留座位 |
| C | **Apple 端上**（`SFSpeechRecognizer` + `AVSpeechSynthesizer`） | 立即可用 | 零 Key、离线可用、无网络计费；音质与豆包双工 TTS 有差距，作为默认过渡层与永久兜底 |

**推荐落地顺序**：先以 C 层打通整条管线并发布（用户立刻可用语音消息），
A 层接口就位等 ToAPIs；届时设置页一键切换，管线其余部分零改动。

诚实性约束：设置页必须如实标注当前语音层
（「端上语音（Apple）」/「ToAPIs · <model>」），不得把端上合成冒充豆包音色。

## 5. 数据模型

`ChatMessageProjection` 新增 kind：`voice`（用户与专家共用），字段复用现有列：

- `imageUrl` → 复用为音频本地路径（沙盒 `attachments/`；与图片同样的
  本地路径渲染规则）；如嫌语义脏，可加 `audioPath` 列——留给实现时定，
  但**禁止**新建平行消息表；
- `text` → 文字稿（用户消息 = ASR 转写；专家消息 = Answer 原文）；
- `secondaryText` → 时长（如「0:23」）；
- 专家语音消息仍携带 `sourceType/uncertainty` 等未核验披露字段。

持久化走现有 Drift 仓库与 append/appendIf 通道；音频文件放
`attachments/`（与图片/文件一致，已在本地数据页的磁盘统计范围内）。

## 6. 交互（对齐微信习惯）

- 输入区新增麦克风/键盘切换钮；**按住说话**，上滑取消，松手发送；
- 录音上限 60 秒，10 秒剩余时轻震提示；录音中显示 `HaloWaveKeysIndicator`；
- 语音气泡：播放/暂停、时长、进度；点「转文字」展开文字稿（默认收起，
  专家气泡因带未核验披露默认**展开**文字稿）；
- 发送后管线状态沿用现有：running 波浪 → 语音气泡落地；
- ASR 失败 → 该条以纯语音消息落地 + 「转写失败，点按重试」；
  TTS 失败 → 专家回复退化为纯文字气泡（Answer 本来就有），不整条失败。

## 7. 安全与计费边界

- `NSMicrophoneUsageDescription`（中文、如实：录制语音消息用于对话）；
- 端上层（C）不产生网络调用与计费；A/B 层每次 ASR/TTS 都过
  `SqliteModelCallJournal` 计费围栏（reserve→dispatched→completed），
  与聊天推理同等对待；
- 音频只存沙盒，不进日志；上游错误正文照旧不落 UI/日志/SQLite；
- 转写文字 = 用户内容，非可信事实；专家 Answer 的信封校验完全不变。

## 8. 验收标准

1. 按住说话 → 松手 → 专家语音回复，全程无键盘参与；
2. 双方语音气泡可播放、可看文字稿；杀 app 重启后历史完整、可再播放；
3. 专家语音气泡保留「未核验」披露；
4. 飞行模式下（C 层）功能完整可用；
5. 设置页如实显示当前语音供给层；
6. ASR/TTS 单点失败不丢用户输入、不整条失败（见 §6 退化路径）；
7. 全量 `flutter test` 绿、`flutter analyze` 干净、真机（iPhone 13 Pro）验收。
