# Flutter Prototype Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reproduce every app-owned screen, mock state, icon and primary interaction from `prototype.html` in the iOS-first Flutter application without redesigning the product.

**Architecture:** Treat `prototype.html` as the visual and interaction contract, and keep the existing product/architecture documents as the behavioral contract. Build a shared Halo design system and fixture repository first, then implement feature-owned routes in small vertical slices; all screens consume immutable fixture models so the same data can later move behind repositories without rewriting widgets.

**Tech Stack:** Flutter 3.44.8, Dart 3.12.2, Material 3 with iOS system typography, go_router 17.3, Riverpod 3.4, phosphor_flutter, Flutter Widget/Golden tests, Xcode 27, iOS 15+.

## Global Constraints

- `prototype.html` is the single source of truth for visible layout, copy, mock data, colors, spacing, radii and interaction states.
- Implement the 23 app-owned page IDs: conversations, chat, chat-details, chat-history, group-chat, group-info, group-context, new-group, contacts, market, market-detail, profile, expert-data, moments, moment-detail, voice, video, media-preview, settings, model-providers, provider-detail, self-hosted-gateway and local-data.
- The four primary destinations remain 对话、专家团、圈层、设置; there is no authentication, account, recharge or platform billing flow.
- Reuse the same Unsplash source URLs and supplied image assets; do not create replacement artwork.
- The HTML contains no inline SVG. Its 89 `ph ph-*` classes come from Phosphor Icons 2.1.1; map them to `phosphor_flutter` icons rather than drawing substitutes.
- iOS owns the device status bar, safe areas, keyboard and home indicator; Flutter reproduces only app-owned content.
- Shared Dart domain and feature code must not import iOS frameworks.
- Every implementation task starts with a failing test and ends with analyze, test and iOS Simulator verification.
- No real Provider, Agent orchestration, media generation, calling or persistence is introduced during static parity work; interactions update deterministic in-memory state.

---

### Task 1: Visual Contract, Icon Map And Shared Components

Status: completed in `d5667e9`.

**Files:**
- Create: `lib/foundation/design_system/halo_tokens.dart`
- Create: `lib/foundation/design_system/halo_icons.dart`
- Create: `lib/foundation/design_system/halo_components.dart`
- Modify: `lib/foundation/design_system/halo_theme.dart`
- Modify: `pubspec.yaml`
- Test: `test/foundation/design_system/halo_design_system_test.dart`

**Interfaces:**
- Consumes: CSS variables and component measurements from `prototype.html`.
- Produces: `HaloColors`, `HaloSpacing`, `HaloRadii`, `HaloIcon`, `HaloPageScaffold`, `HaloNavBar`, `HaloTabBar`, `HaloAvatar`, `HaloTag`, `HaloSearchField`, `HaloSectionLabel`, `HaloSettingsGroup`, `HaloSettingsRow`.

- [ ] **Step 1: Write the failing token and component test**

```dart
testWidgets('Halo design tokens reproduce the prototype contract', (tester) async {
  expect(HaloColors.accent, const Color(0xFF5668D8));
  expect(HaloColors.soft, const Color(0xFFF4F5F7));
  expect(HaloRadii.card, 14);
  await tester.pumpWidget(
    const MaterialApp(home: HaloPageScaffold(title: '对话', body: SizedBox())),
  );
  expect(find.text('对话'), findsOneWidget);
});
```

- [ ] **Step 2: Run the focused test**

Run: `flutter test test/foundation/design_system/halo_design_system_test.dart`

Expected: FAIL because the shared tokens and widgets do not exist.

- [ ] **Step 3: Add Phosphor Flutter and implement the shared contract**

Run: `flutter pub add phosphor_flutter`

Implement exact prototype values: ink `#171923`, muted `#8B909A`, line `#E9EBEF`, soft `#F4F5F7`, paper `#FFFFFF`, accent `#5668D8`, accentDeep `#3F50B7`, accentSoft `#EEF0FF`, green `#2E9D72`, amber `#CF8A2E`, red `#E75B62`, navy `#28314E`; navbar height 53, search height 38, primary tab area 80, avatar 50 with radius 13, settings group radius 14.

- [ ] **Step 4: Run design-system tests and analysis**

Run: `flutter analyze && flutter test test/foundation/design_system/halo_design_system_test.dart`

Expected: PASS with zero analyzer findings.

- [ ] **Step 5: Commit**

```bash
git add apps/mobile/lib/foundation apps/mobile/test/foundation apps/mobile/pubspec.yaml apps/mobile/pubspec.lock
git commit -m "feat: add Halo visual design system"
```

---

### Task 2: Deterministic Fixtures And Four Primary Screens

Status: completed in `ed10bc1`.

**Files:**
- Create: `lib/domain/models/halo_fixture_models.dart`
- Create: `lib/mock/fixtures/halo_fixtures.dart`
- Create: `lib/features/conversations/conversations_page.dart`
- Create: `lib/features/expert_team/expert_team_page.dart`
- Create: `lib/features/circle/circle_page.dart`
- Create: `lib/features/settings/settings_page.dart`
- Modify: `lib/app/app_shell.dart`
- Modify: `lib/app/router.dart`
- Delete: `lib/features/home/home_destination_page.dart`
- Test: `test/features/primary_navigation_test.dart`

**Interfaces:**
- Consumes: Task 1 design-system components.
- Produces: immutable `ConversationFixture`, `ExpertFixture`, `CirclePostFixture`, `SettingSectionFixture`, `HaloFixtures`, and four production primary pages.

- [ ] **Step 1: Write the failing fixture and primary-navigation tests**

```dart
test('fixtures preserve prototype coverage', () {
  expect(HaloFixtures.conversations.length, 12);
  expect(HaloFixtures.marketExperts.length, 50);
  expect(HaloFixtures.circlePosts.length, greaterThanOrEqualTo(5));
});

testWidgets('four destinations show prototype headings and rows', (tester) async {
  await tester.pumpWidget(const HaloApp());
  expect(find.text('通用助理'), findsOneWidget);
  await tester.tap(find.text('专家团'));
  await tester.pumpAndSettle();
  expect(find.text('AI 市场'), findsOneWidget);
});
```

- [ ] **Step 2: Run the focused test**

Run: `flutter test test/features/primary_navigation_test.dart`

Expected: FAIL because the feature-owned pages and full fixtures do not exist.

- [ ] **Step 3: Implement fixtures and the four screens**

Move all visible primary-screen copy and stable IDs from the HTML into immutable fixtures. Use exact 50/13/14/17/15 px type hierarchy, 11 px conversation row gap, 50 px avatar, `#E9EBEF` separators, 80 px bottom navigation and the same Phosphor glyph for each HTML class.

- [ ] **Step 4: Verify the four screens**

Run: `flutter analyze && flutter test test/features/primary_navigation_test.dart`

Expected: PASS. Launch iPhone 17 Pro and capture all four destinations at 393 logical pixels.

- [ ] **Step 5: Commit**

```bash
git add apps/mobile/lib apps/mobile/test/features
git commit -m "feat: reproduce Halo primary screens"
```

---

### Task 3: Single-Agent Conversation And Chat Details

Status: completed in `934eeaf`.

**Files:**
- Create: `lib/domain/models/message_fixture.dart`
- Create: `lib/features/conversations/chat_page.dart`
- Create: `lib/features/conversations/chat_details_page.dart`
- Create: `lib/features/conversations/widgets/message_widgets.dart`
- Create: `lib/features/conversations/widgets/chat_composer.dart`
- Modify: `lib/app/app.dart`
- Modify: `lib/app/router.dart`
- Test: `test/features/conversations/single_chat_test.dart`

**Interfaces:**
- Consumes: `ConversationFixture`, Task 1 components and `/chat/:conversationId`.
- Produces: message renderers for text, quote, file, image, gallery, voice, link, checklist, calendar, metric, table, chart, risk, error, progress and system notice; `ChatComposer`.

- [ ] **Step 1: Write failing route and format tests**

```dart
testWidgets('single chat renders every prototype message family', (tester) async {
  await tester.pumpWidget(HaloApp(initialLocation: '/chat/general-assistant'));
  await tester.pumpAndSettle();
  expect(find.text('通用助理'), findsWidgets);
  expect(find.byKey(const Key('message-file')), findsWidgets);
  expect(find.byKey(const Key('message-gallery')), findsWidgets);
  expect(find.byKey(const Key('message-risk')), findsWidgets);
});
```

- [ ] **Step 2: Run the test and confirm missing routes/widgets**

Run: `flutter test test/features/conversations/single_chat_test.dart`

Expected: FAIL with no `/chat/:conversationId` route.

- [ ] **Step 3: Implement the route, message registry and details page**

Match HTML bubble widths, radii, avatar sizes, composer safe-area behavior and plus-menu actions. Voice/video actions appear only in the one-to-one plus menu.

- [ ] **Step 4: Run focused and full tests**

Run: `flutter analyze && flutter test test/features/conversations/single_chat_test.dart && flutter test`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/mobile/lib apps/mobile/test/features/conversations
git commit -m "feat: add single-agent chat experience"
```

---

### Task 4: Multi-Agent Group Chat And Orchestration Presentation

Status: completed in `88cb54a`.

**Files:**
- Create: `lib/domain/models/group_run_fixture.dart`
- Create: `lib/features/group_chat/group_chat_controller.dart`
- Create: `lib/features/group_chat/group_chat_page.dart`
- Create: `lib/features/group_chat/group_info_page.dart`
- Create: `lib/features/group_chat/group_context_page.dart`
- Create: `lib/features/group_chat/widgets/reply_mode_bar.dart`
- Modify: `lib/app/router.dart`
- Test: `test/features/group_chat/group_chat_modes_test.dart`

**Interfaces:**
- Consumes: message widgets from Task 3.
- Produces: `GroupReplyMode.auto`, `.mentioned`, `.all`; deterministic discussion phases; stop action; summary card; group member and shared-context routes.

- [ ] **Step 1: Write failing mode tests**

```dart
testWidgets('group chat exposes exactly three reply modes', (tester) async {
  await tester.pumpWidget(HaloApp(initialLocation: '/chat/group-product'));
  expect(find.text('自动选择'), findsOneWidget);
  expect(find.text('@某个 Agent'), findsOneWidget);
  expect(find.text('@所有人'), findsOneWidget);
  expect(find.byIcon(PhosphorIcons.phone()), findsNothing);
});
```

- [ ] **Step 2: Confirm failure**

Run: `flutter test test/features/group_chat/group_chat_modes_test.dart`

Expected: FAIL because group chat is not implemented.

- [ ] **Step 3: Implement group screens and in-memory controller**

Use the exact “iOS 产品小组”“本周信息研判”“内容发布团队” fixtures. `all` progresses through 观点收集、交叉讨论、总结 and can be stopped; no group call controls exist.

- [ ] **Step 4: Verify**

Run: `flutter analyze && flutter test test/features/group_chat/group_chat_modes_test.dart && flutter test`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/mobile/lib apps/mobile/test/features/group_chat
git commit -m "feat: add multi-agent group chat states"
```

---

### Task 5: Expert Team, Market, Profile And Expert Data

Status: completed in `3b2f6cd`.

**Files:**
- Create: `lib/features/expert_team/expert_profile_page.dart`
- Create: `lib/features/expert_team/expert_data_page.dart`
- Create: `lib/features/agent_market/agent_market_page.dart`
- Create: `lib/features/agent_market/agent_market_detail_page.dart`
- Create: `lib/features/agent_market/agent_market_controller.dart`
- Modify: `lib/app/router.dart`
- Test: `test/features/expert_team/expert_market_test.dart`

**Interfaces:**
- Consumes: 50 `ExpertFixture` records.
- Produces: category/search filters, ten-item incremental loading, add/remove state, shared expert detail, model override and publish permission controls.

- [ ] **Step 1: Write failing 50-expert tests**

```dart
testWidgets('market exposes all 50 experts incrementally', (tester) async {
  await tester.pumpWidget(HaloApp(initialLocation: '/experts/market'));
  expect(find.byType(ExpertMarketCard), findsNWidgets(10));
  await tester.tap(find.text('加载更多'));
  await tester.pump();
  expect(find.byType(ExpertMarketCard), findsNWidgets(20));
});
```

- [ ] **Step 2: Confirm failure**

Run: `flutter test test/features/expert_team/expert_market_test.dart`

Expected: FAIL because market routes and cards do not exist.

- [ ] **Step 3: Implement all expert routes and state**

Map every prototype category, expert name, role, model label, avatar URL, description and tag without generated replacements.

- [ ] **Step 4: Verify**

Run: `flutter analyze && flutter test test/features/expert_team/expert_market_test.dart && flutter test`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/mobile/lib apps/mobile/test/features/expert_team
git commit -m "feat: add expert team and market"
```

---

### Task 6: Circle Feed And Result Detail

**Files:**
- Create: `lib/features/circle/circle_controller.dart`
- Create: `lib/features/circle/circle_post_card.dart`
- Create: `lib/features/circle/moment_detail_page.dart`
- Modify: `lib/app/router.dart`
- Test: `test/features/circle/circle_flow_test.dart`

**Interfaces:**
- Consumes: `CirclePostFixture` and media preview contract.
- Produces: reverse-chronological expert feed, per-expert filtering, source navigation, save action and continue-chat action.

- [ ] **Step 1: Write failing feed tests**

```dart
testWidgets('circle is an expert result feed with five mock states', (tester) async {
  await tester.pumpWidget(HaloApp(initialLocation: '/circle'));
  expect(find.text('主动分享'), findsWidgets);
  expect(find.text('监控变化'), findsOneWidget);
  expect(find.text('任务失败'), findsOneWidget);
});
```

- [ ] **Step 2: Confirm failure**

Run: `flutter test test/features/circle/circle_flow_test.dart`

Expected: FAIL until all feed states exist.

- [ ] **Step 3: Implement cards and detail navigation**

Match the source badges, three-image gallery, result link, status card, action row and detail bottom bar from the HTML.

- [ ] **Step 4: Verify**

Run: `flutter analyze && flutter test test/features/circle/circle_flow_test.dart && flutter test`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/mobile/lib apps/mobile/test/features/circle
git commit -m "feat: add expert circle result feed"
```

---

### Task 7: Settings, Provider Forms, Gateway And Local Data

Status: completed in `ac8df70`.

**Files:**
- Create: `lib/domain/models/provider_fixture.dart`
- Create: `lib/features/providers/provider_controller.dart`
- Create: `lib/features/providers/model_providers_page.dart`
- Create: `lib/features/providers/provider_detail_page.dart`
- Create: `lib/features/gateway/self_hosted_gateway_page.dart`
- Create: `lib/features/local_data/local_data_page.dart`
- Modify: `lib/features/settings/settings_page.dart`
- Modify: `lib/app/router.dart`
- Test: `test/features/settings/settings_provider_test.dart`

**Interfaces:**
- Consumes: local-only fixture state.
- Produces: ToAPIs, DeepSeek, OpenAI, Anthropic, Gemini, custom compatible, local model, Doubao voice and Vidu cards; connection/error/offline states; local save/remove/toggle flows.

- [ ] **Step 1: Write failing provider-state tests**

```dart
testWidgets('provider list preserves all prototype provider states', (tester) async {
  await tester.pumpWidget(HaloApp(initialLocation: '/settings/providers'));
  expect(find.text('ToAPIs'), findsOneWidget);
  expect(find.text('未配置'), findsWidgets);
  expect(find.text('连接异常'), findsOneWidget);
  expect(find.text('服务离线'), findsOneWidget);
});
```

- [ ] **Step 2: Confirm failure**

Run: `flutter test test/features/settings/settings_provider_test.dart`

Expected: FAIL because nested settings pages do not exist.

- [ ] **Step 3: Implement settings routes and safe demo state**

Do not persist or transmit keys. API Key fields display masked local fixture values and save/test actions only mutate in-memory status.

- [ ] **Step 4: Verify**

Run: `flutter analyze && flutter test test/features/settings/settings_provider_test.dart && flutter test`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/mobile/lib apps/mobile/test/features/settings
git commit -m "feat: add local provider and data settings"
```

---

### Task 8: Chat History, Group Creation And Shared Context

**Files:**
- Create: `lib/features/chat_history/chat_history_controller.dart`
- Create: `lib/features/chat_history/chat_history_page.dart`
- Create: `lib/features/expert_team/new_group_page.dart`
- Modify: `lib/features/group_chat/group_context_page.dart`
- Modify: `lib/app/router.dart`
- Test: `test/features/chat_history/chat_history_modes_test.dart`

**Interfaces:**
- Consumes: existing history fixtures and preview navigation.
- Produces: mutually exclusive `searchIdle`, `searchResults` and `categoryCards` modes; highlighted results; date-grouped media/files/links/artifacts; group member selection and context scope toggles.

- [ ] **Step 1: Write failing history-mode tests**

```dart
testWidgets('history defaults to an empty search-first state', (tester) async {
  await tester.pumpWidget(HaloApp(initialLocation: '/chat/general-assistant/history'));
  expect(find.byType(TextField), findsOneWidget);
  expect(find.byType(HistoryResultRow), findsNothing);
  expect(find.byType(HistoryDateSection), findsNothing);
});
```

- [ ] **Step 2: Confirm failure**

Run: `flutter test test/features/chat_history/chat_history_modes_test.dart`

Expected: FAIL because the history controller and route do not exist.

- [ ] **Step 3: Implement search and category card states**

Keep search results as highlighted rows only; keep every non-search category as iOS date-grouped cards exactly as the HTML.

- [ ] **Step 4: Verify**

Run: `flutter analyze && flutter test test/features/chat_history/chat_history_modes_test.dart && flutter test`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/mobile/lib apps/mobile/test/features/chat_history
git commit -m "feat: add chat history and group creation"
```

---

### Task 9: Media Preview And Call Demonstration Screens

**Files:**
- Create: `lib/domain/models/media_preview_item.dart`
- Create: `lib/features/media_preview/media_preview_page.dart`
- Create: `lib/features/calls/voice_call_demo_page.dart`
- Create: `lib/features/calls/video_call_demo_page.dart`
- Modify: `lib/app/router.dart`
- Test: `test/features/media/media_and_call_demo_test.dart`

**Interfaces:**
- Consumes: existing URLs and file/link metadata.
- Produces: image gallery pagination, document mock preview, link preview, share feedback, one-to-one voice/video demonstration controls.

- [ ] **Step 1: Write failing media tests**

```dart
testWidgets('media preview pages reuse the source assets', (tester) async {
  await tester.pumpWidget(HaloApp(initialLocation: '/preview/image/gallery-1'));
  expect(find.text('1 / 4'), findsOneWidget);
  expect(find.byIcon(PhosphorIcons.shareNetwork()), findsOneWidget);
});
```

- [ ] **Step 2: Confirm failure**

Run: `flutter test test/features/media/media_and_call_demo_test.dart`

Expected: FAIL because preview and call routes do not exist.

- [ ] **Step 3: Implement demonstration pages**

These pages reproduce prototype visuals and toggles only; they must not request microphone/camera permission or initialize call/media SDKs.

- [ ] **Step 4: Verify**

Run: `flutter analyze && flutter test test/features/media/media_and_call_demo_test.dart && flutter test`

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/mobile/lib apps/mobile/test/features/media
git commit -m "feat: add media and call demonstration screens"
```

---

### Task 10: Full Route Coverage And Visual Parity Gate

**Files:**
- Create: `test/app/all_routes_smoke_test.dart`
- Create: `test/goldens/primary_screens_golden_test.dart`
- Create: `design-qa.md`
- Create: `docs/quality/flutter-parity/`
- Modify: `README.md`

**Interfaces:**
- Consumes: all 23 route implementations and existing HTML QA screenshots.
- Produces: route coverage matrix, 393×852 reference/Flutter comparison captures and a blocking design QA report.

- [ ] **Step 1: Write failing route coverage test**

```dart
for (final location in HaloRouteCatalog.allPrototypeLocations) {
  testWidgets('route renders: $location', (tester) async {
    await tester.pumpWidget(HaloApp(initialLocation: location));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
```

- [ ] **Step 2: Run all verification**

Run: `flutter analyze && flutter test && flutter build ios --simulator`

Expected: all 23 routes render, all tests pass, and the Simulator build succeeds.

- [ ] **Step 3: Capture and compare**

Capture the same states and 393×852 logical viewport as the HTML reference. Compare app-owned content side by side and document every spacing, crop, type, color, radius and icon mismatch in `design-qa.md`.

- [ ] **Step 4: Fix all P0/P1/P2 findings**

Repeat capture and comparison until `design-qa.md` contains:

```text
final result: passed
```

- [ ] **Step 5: Commit**

```bash
git add apps/mobile
git commit -m "test: complete Flutter prototype parity gate"
```
