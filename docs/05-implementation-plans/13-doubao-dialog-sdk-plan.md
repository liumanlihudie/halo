# 豆包 Dialog SDK 接入计划（替换 WS 直连）

日期：2026-07-30
起因：WS 直连通话不稳定——扬声器的声音被麦克风收回，服务端判定用户开口
而打断自己的回复。半双工能止住，但等于废掉双工打断，产品负责人已否决。
SDK 内置 AEC 回声消除，是这个问题的正解。

## 为什么是 SDK

- 官方集成指南原文：「Dialog 语音对话过程中，如果既启用录音机，又启用播放器，
  则设备会录入播放的人声而影响对话。故 Dialog SDK 内置 AEC 能力」——正是现状。
- SDK 自带录音机与播放器，输入输出时序对齐，AEC 才能生效；我们自己用
  record + audioplayers 无法保证这一点。
- 人设注入方式不变：SDK 的 `DIRECTIVE_START_ENGINE` 参数就是现在发的
  `dialog.bot_name/system_role/speaking_style`，专家人设不会丢。

## 任务拆分

### T1 设置页：端到端 Key 拆成三个字段（另一会话拥有该文件，先协调）
- `KeyOnlyService.doubaoRealtimeAudio` 改为三字段服务：APP ID、APP KEY、
  ACCESS TOKEN。APP ID 与 APP KEY 非敏感，可存 SQLite；TOKEN 走 Keychain。
- 迁移：现有 `appId:accessToken` 单值记录读出后拆分，缺 APP KEY 时置空。

### T2 iOS 依赖与模型文件
- `ios/Podfile`：`pod 'SpeechEngineToB', '0.0.14.7'`、`pod 'SocketRocket', '0.6.1'`
- AEC 模型 `aec.model` 打进 bundle（文档附件下载），路径传给 SDK。
- 注意：会引入 CocoaPods，首次构建变慢；`Podfile.lock` 要提交。

### T3 原生桥接 `ios/Runner/DoubaoDialogEngine.swift`
- MethodChannel `halo.dialog/engine`：`start`（传 appId/appKey/token/
  systemRole/botName/speaker/model）、`stop`、`interrupt`。
- EventChannel 回传：ASR 开始/文本/结束、Chat 文本/结束、引擎错误。
- 关键配置：`PARAMS_KEY_ENABLE_AEC_BOOL=true` + AEC 模型路径；
  RECORDER_TYPE_RECORDER（用 SDK 录音机）；播放器保持开启。

### T4 Dart 侧替换
- 新 `DoubaoDialogCall` 实现现有 `VoiceCallController` 依赖的接口形状，
  `VolcanoRealtimeDialog`/`DeviceCallMicrophone`/`DeviceCallSpeaker` 退役
  （WS 客户端与其 4 条契约测试保留，作为无 SDK 环境的回退路径）。
- 通话页与记录、拨号态、距离感应逻辑不变。

### T5 验收
- 真机：连续对话 3 轮不中断（当前一段就断）；说话能打断回复；
  贴耳切听筒；挂断后对话流留记录。
- 全量 `flutter test --concurrency=1` 绿；`flutter analyze` 干净。

## 风险
- SDK 为闭源二进制，开源仓库需在 README 说明其许可与来源。
- 三字段鉴权与 WS 直连的两字段不同，两条路径需并存一段时间。
