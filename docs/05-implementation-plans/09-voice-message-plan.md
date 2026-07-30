# 语音消息实现计划

日期：2026-07-30（当日修订：主路改为火山引擎直连）
依据：`docs/04-feature-specs/07-voice-message-design.md`
前置事实：ToAPIs 当前无音频端点（设计 §3.1）；产品决策直接接火山引擎
豆包语音。TTS 接口形态与参数已从产品负责人跑通的 HTML_xl3.0 项目实证冻结
（设计 §3.2）；ASR 是唯一待定段（T0）。端上层与 ToAPIs 层留座不建。

## 任务拆分（每项一个提交，附验证门槛）

### T0 ASR 路线定案（唯一未实证段；TTS 参数已从 HTML_xl3.0 工作代码冻结）

- 由产品负责人用自己的 Key 实测：`X-Api-Key` 认证是否适用于
  `/api/v3/auc/bigmodel/submit` 录音文件识别，以及 m4a 支持情况
  （测法可参考 HTML_xl3.0 的调用风格；凭证不入库不入文档）
- 不通则 ASR 取 iOS 端上 `SFSpeechRecognizer`（延续 HTML_xl3.0 用本地
  vosk 的架构先例），火山侧只做 TTS
- 门槛：结论回写本文档 §依据；不阻塞 T1–T4 动工

### T1 语音供给接口 + 火山 Provider 配置

- Create: `lib/model_runtime/speech_runtime.dart`
  （`SpeechTranscriber` / `SpeechSynthesizer` / 请求响应模型 / 安全错误映射）
- Modify: `provider_config.dart`（新 ProviderKind.volcanoSpeech：
  单 API Key 走 SecretRef/Keychain；speaker / resource id / 采样率为
  非敏感配置字段，默认值取 HTML_xl3.0 实证参数：
  `seed-tts-2.0` / `zh_female_vv_uranus_bigtts` / mp3 / 24000）
- Modify: 端点白名单新增 `openspeech.bytedance.com` 与
  `/api/v3/tts/unidirectional`（ASR 路径视 T0 结论增补）——
  安全边界改动，独立小提交便于评审
- Modify: 设置页新增「火山引擎 · 豆包语音」Provider 卡片
  （三字段，Token 用显式粘贴；连接测试复用现有只读探测模式）
- Test: 配置持久化轮转、Token 不出 Keychain、白名单拒绝其余路径
- 门槛：`flutter analyze` 干净；凭证三元组不进日志断言

### T2 火山语音适配器

- Create: `lib/model_runtime/volcano_speech.dart`
  （TTS：POST unidirectional → 读完整分块响应 → 逐行解析 JSON、拼接
  base64 片段 → 写目标路径；文本先过 markdown 剥离（HTML_xl3.0 实证坑：
  LLM 输出直接合成会读出格式符号）；≤1000 字上限对齐 Answer 的 1200 字
  需截断策略：超长按句边界分两次合成拼接；
  ASR 按 T0 定案实现（火山 auc 或端上）；
  全部走安全传输 + `SqliteModelCallJournal` 计费围栏 + 错误脱敏；
  分块响应总量上限独立设定并评审——mp3@24kHz 每分钟约 180KB，
  预留 4MB 足够且有界）
- Test: 形状合同测试用 HTML_xl3.0 实证响应形状（JSON 行 + base64 data）：
  成功链、片段损坏 fail-closed、超长文本分段、限流 Retry-After、
  错误正文不外泄
- 门槛：`flutter analyze` 干净

### T3 录音服务

- Create: `lib/features/single_chat/attachments/voice_recorder_service.dart`
  （`record` 包或 AVAudioEngine channel；m4a；≤60s 硬上限；
  产物落 `attachments/<uuid>.m4a`，复用 `ChatAttachmentService` 的目录与 uuid 模式）
- Test: 注入 fake 录音器：时长上限截断、取消清理临时文件、产物路径规范

### T4 消息模型与气泡

- Modify: `chat_message_repository.dart`（`ChatMessageKind.voice`；
  编解码轮转测试；老历史无 voice 消息，无迁移风险——仍加解码兼容测试）
- Modify: `single_chat_page.dart`（语音气泡：播放/暂停/时长/文字稿开合；
  播放用 `audioplayers` 或 AVPlayer channel；专家气泡文字稿默认展开 + 未核验披露）
- Test: widget 测试（气泡渲染、文字稿开合、未核验标识存在）

### T5 发送管线接线

- Modify: `single_chat_controller.dart`（新入口 `submitVoice(recordingPath)`：
  ASR → 以转写文字走现有 `submit` 通道，用户消息以 voice kind 落库并绑定音频路径；
  ASR 失败按设计 §6 退化）
- Modify: 专家回复侧：Answer 落地后异步 TTS，成功则把该消息升级为 voice kind
  （appendIf/替换语义沿用现有提交令牌机制），失败保持纯文字——不阻塞回复展示
- Test: controller 测试覆盖成功链、ASR 失败链、TTS 失败链、重启后重放

### T6 输入区交互

- Modify: `single_chat_page.dart`（麦克风/键盘切换、按住说话手势、上滑取消、
  录音中 `HaloWaveKeysIndicator`、剩余 10 秒提示）
- Test: widget 测试（手势状态机：按下/上滑取消/松手发送）

### T7 设置页语音分组 + 供给层如实标注

- Modify: 设置页新增「语音」组：当前层如实显示「火山引擎 · 豆包语音」
  （未配置凭证时置灰并引导配置）、专家语音回复开关（默认开）
- Test: widget 测试（标注文案与实际层一致）

### 留座不建（外部条件触发时再排期）

- **ToAPIs 音频层**：其端点上线后，按 T1/T2 同样的白名单评审 + 文档形状
  测试流程接入（可共用现有 ToAPIs Key）；目录侧 `type=audio` 模型已保留
  （2026-07-30 目录修复）。
- **Apple 端上层**：离线兜底需求出现时再建
  （`SFSpeechRecognizer`/`AVSpeechSynthesizer`，需补
  `NSSpeechRecognitionUsageDescription`）。

## 顺序与并行

T0 最先（阻塞 T2 的参数定稿，不阻塞 T1/T3 动工）；T1、T3 可并行；
T2 依赖 T0/T1；T4 依赖 T1/T3 的类型；T5 依赖 T1–T4；T6 依赖 T3；
T7 随 T5 后收尾。

## 统一门槛（每个提交）

全量 `flutter test --concurrency=1` 绿；`flutter analyze` 干净；
`dart format` 无 diff；涉及 UI 的项真机装机自验后再交付验收。
