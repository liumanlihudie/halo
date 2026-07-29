# Halo Mobile

Halo 的 iOS-first Flutter 工程。当前里程碑提供无登录的四栏应用壳层：对话、专家团、圈层、设置；数据均为确定性本地样例，不调用真实模型、Gateway 或音视频服务。

## 环境

- Flutter 3.44.8 或兼容稳定版
- Dart 3.12 或兼容版本
- Xcode 27
- CocoaPods 1.17
- iOS 15+

## 运行

```bash
flutter pub get
flutter run -d "iPhone 17 Pro"
```

若只需验证工程：

```bash
flutter analyze
flutter test
flutter build ios --simulator
```

## 结构

- `lib/app/`：应用入口、路由和四栏 Shell。
- `lib/foundation/`：设计系统及后续数据库、文件、安全、网络适配。
- `lib/features/`：按业务 Feature 组织的界面与控制器。
- `test/`：领域与 Widget 测试。
- `ios/`：iOS Runner，Bundle ID 当前为 `com.cofe.haloMobile`。
- `docs/`：移动端规格与实施计划。

第一阶段范围与约束以 [移动端设计规格](docs/superpowers/specs/2026-07-28-halo-mobile-app-design.md) 为准。
