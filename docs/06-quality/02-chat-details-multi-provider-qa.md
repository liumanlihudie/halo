# Design QA — Chat Details, Expert Profile, and Multi-Provider

Date: 2026-07-28

## Visual target

- Preserve familiar iOS IM information hierarchy: member/profile first, then content search, notification controls, appearance/data actions, and destructive actions at the bottom.
- Do not reproduce WeChat colors, icon artwork, spacing, or page composition pixel-for-pixel.
- Halo-specific anchors: indigo accent, AI asset categories, Agent model reference, proactive work, circle publishing permission, and multi-Provider health.

## Reference-to-build comparison

The combined comparison is stored at:

- `docs/06-quality/assets/chat-details-expert-profile-2026-07-28/compare.html`

## Passes

- Chat details uses the familiar control order while adding AI成果 and expert reporting.
- Group info adds shared context, discussion policy, auto-summary, mixed-provider members, and circle publishing.
- Expert profile exposes model, expert data, current activity, circle history, and per-expert publishing permission.
- Model service UI visibly separates Provider status, `providerId + modelId`, global defaults, and per-Agent overrides.
- ToAPIs is presented as the recommended aggregator, not a mandatory gateway.
- Gemini failure, local model offline/no-key, and unconfigured Provider states are visible.
- Visual inspection found no horizontal overflow in the phone or active iOS scrolling surface.
- Runtime console inspection found no warnings or errors.

## Deliberate differences

- Halo uses a light card system and indigo accent rather than WeChat dark/green brand expressions.
- Circle remains an unclassified expert feed rather than a Moments clone.
- AI-specific actions and provenance replace social contact metadata.

## Remaining prototype limits

- Provider credentials and model discovery are mock state only; no real Keychain or network calls occur in this HTML prototype.
- Export, system share, photo selection, and destructive actions stop at simulated sheets/toasts.
- The prototype uses one HTML runtime; native route and persistence boundaries remain implementation work for the Flutter/iOS app.

## 2026-07-29 — Expert Team Duplicate Search Removal

- Removed the redundant search field below the “专家团” navigation bar.
- Kept the top-right search action and add-expert action unchanged.
- Verified the expert list now starts with the AI 市场 card.
- Expert page duplicate search count: `0`.
- Top-right search action count: `1`.
- Phone and expert-list horizontal overflow: `0px`.
- Browser console warnings/errors: `0`.
- Regression suite: `39 passed, 0 failed`.
- Evidence: `docs/06-quality/assets/remove-duplicate-search-2026-07-29/01-expert-team.png`.

final result: passed
