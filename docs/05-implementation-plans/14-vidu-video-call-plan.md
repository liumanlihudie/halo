# Vidu S1 视频通话接入计划

日期：2026-07-31
契约来源：生数官方文档（飞书 wiki，已授权读取）+ Vidu-S1 GitHub 引路页。
以下字段均为文档原文，非推测。

## 接口契约

1. **创建直播会话**
   - `POST /live/v1/lives`
   - 鉴权头：`Authorization: Token vda_xxx`（API Key 形如 `vda_`）
   - 返回：`live` 与 `rtc`；`rtc` 内含 `app_id` / `channel_id` / `user_id` / `token`
2. **应用层信令 WebSocket**
   - `GET /live/ws/live/connect?live_id={live_id}&conn_id={conn_id}`
   - 连接后首帧 `conn_init`：
     `{"type":1,"live_id":"...","conn_id":"uuid","seq_id":1,
       "payload":{"conn_init":{"version":1}}}`
   - 收到 `conn_init_ack.success == true` 方可用；视频模式可能先回 `NOT_READY`，
     文档要求等 2 秒重试（正常现象）
   - 文本消息走这条连接（`text_msg`）
3. **音视频媒体：阿里 RTC（AliRTC）**
   - 用 `rtc.token` 调 AliRTC 的 `joinChannel`
   - 音频模式上行麦克风；视频模式上行摄像头+麦克风
   - 数字人画面由服务端发布为远端流（540P / 25FPS）

## 与语音通话的关键差异

**媒体不由我们自己推流**——语音通话是我们直接 WebSocket 传 PCM，视频通话必须
接入 **AliRTC SDK**。iOS 侧是原生依赖（CocoaPods `AliRTCSdk`），这是这个功能
的主要工作量，也是唯一的技术风险点。

## 任务拆分

- **T1** `lib/model_runtime/vidu_live.dart`：创建会话（POST）+ 信令 WebSocket
  （conn_init 握手、NOT_READY 重试、text_msg），契约测试用本地假服务器覆盖
  握手成功链、NOT_READY 重试、鉴权失败脱敏。**不依赖 AliRTC，可先做完。**
- **T2** iOS 原生桥接 AliRTC：CocoaPods 引入、joinChannel、本地麦克风/摄像头
  上行、远端视频流渲染（PlatformView）。风险：SDK 体积与许可证；开源仓库需在
  README 标注。
- **T3** 通话页：复用语音通话页结构（头像→远端画面、听筒/扬声器、挂断、
  通话记录），视频模式增加摄像头开关与前后置切换。
- **T4** 角色设定：文档支持「角色设定输入」（约 300 中文字），把我们专家的
  人设注入进去——与语音通话同一条红线：不注入就变成通用数字人。
- **T5** 真机验收：画面出得来、能对话、挂断留记录、Key 无效时如实报错。

## 前置

Vidu 的 API Key（`vda_` 开头）与点数余额。设置页已有 `vidu` 那格，格式待
T1 确认后如实标注。
