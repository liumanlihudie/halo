# 语音消息实现计划

日期：2026-07-30
依据：`docs/04-feature-specs/07-voice-message-design.md`
前置事实：ToAPIs 当前无音频端点（设计文档 §3），首发走 Apple 端上层（C），
ToAPIs 层（A）接口就位待其上线。

## 任务拆分（每项一个提交，附验证门槛）

### T1 语音供给接口 + 端上实现

- Create: `lib/model_runtime/speech_runtime.dart`
  （`SpeechTranscriber` / `SpeechSynthesizer` / 请求响应模型 / 安全错误映射）
- Create: `lib/model_runtime/on_device_speech.dart`
  （`SFSpeechRecognizer` 经 platform channel 或 `speech_to_text` 包；
  `AVSpeechSynthesizer` 经 `flutter_tts` 包写文件。选包时先查维护状态，
  不可用则写薄 platform channel——两个 API 都是几十行 Swift）
- Test: 纯 Dart 合同测试（注入 fake 引擎）：转写成功/失败映射、
  合成写入目标路径、错误不泄原文
- 门槛：`flutter analyze` 干净；权限串进 `Info.plist`
  （`NSMicrophoneUsageDescription` + `NSSpeechRecognitionUsageDescription`）

### T2 录音服务

- Create: `lib/features/single_chat/attachments/voice_recorder_service.dart`
  （`record` 包或 AVAudioEngine channel；m4a；≤60s 硬上限；
  产物落 `attachments/<uuid>.m4a`，复用 `ChatAttachmentService` 的目录与 uuid 模式）
- Test: 注入 fake 录音器：时长上限截断、取消清理临时文件、产物路径规范

### T3 消息模型与气泡

- Modify: `chat_message_repository.dart`（`ChatMessageKind.voice`；
  编解码轮转测试；老历史无 voice 消息，无迁移风险——仍加解码兼容测试）
- Modify: `single_chat_page.dart`（语音气泡：播放/暂停/时长/文字稿开合；
  播放用 `audioplayers` 或 AVPlayer channel；专家气泡文字稿默认展开 + 未核验披露）
- Test: widget 测试（气泡渲染、文字稿开合、未核验标识存在）

### T4 发送管线接线

- Modify: `single_chat_controller.dart`（新入口 `submitVoice(recordingPath)`：
  ASR → 以转写文字走现有 `submit` 通道，用户消息以 voice kind 落库并绑定音频路径；
  ASR 失败按设计 §6 退化）
- Modify: 专家回复侧：Answer 落地后异步 TTS，成功则把该消息升级为 voice kind
  （appendIf/替换语义沿用现有提交令牌机制），失败保持纯文字——不阻塞回复展示
- Test: controller 测试覆盖成功链、ASR 失败链、TTS 失败链、重启后重放

### T5 输入区交互

- Modify: `single_chat_page.dart`（麦克风/键盘切换、按住说话手势、上滑取消、
  录音中 `HaloWaveKeysIndicator`、剩余 10 秒提示）
- Test: widget 测试（手势状态机：按下/上滑取消/松手发送）

### T6 设置页语音分组 + 供给层如实标注

- Modify: 设置页新增「语音」组：当前层显示（端上 / ToAPIs 待上线置灰）、
  专家语音回复开关（默认开）
- Test: widget 测试（标注文案与实际层一致）

### T7（待 ToAPIs 上线音频端点后）ToAPIs 层接入

- Modify: `provider_config.dart` / `unary_http_transport.dart`
  （端点白名单新增 `/audio/transcriptions`、`/audio/speech` 类路径——
  安全边界改动，独立评审）
- Create: `lib/model_runtime/toapis_speech.dart`（走现有 Key、计费围栏、脱敏）
- 目录侧 `type=audio` 模型已被保留（2026-07-30 目录修复），选择器直接可用
- 门槛：文档形状回归测试（如 list-models 先例）+ 真机实测后才可设为默认层

## 顺序与并行

T1、T2 可并行；T3 依赖 T1/T2 的类型；T4 依赖 T1–T3；T5 依赖 T2；
T6 随 T4 后收尾。T7 独立等外部条件。

## 统一门槛（每个提交）

全量 `flutter test --concurrency=1` 绿；`flutter analyze` 干净；
`dart format` 无 diff；涉及 UI 的项真机装机自验后再交付验收。
