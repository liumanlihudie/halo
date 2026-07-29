# Flutter Visual QA — Round 2

## Comparison target

- Source visual truth: `/Users/cofe/IOS-IM/prototype.html`
- Source captures:
  - `/Users/cofe/IOS-IM/docs/06-quality/assets/flutter/qa-round-2/source-conversations-phone.png`
  - `/Users/cofe/IOS-IM/docs/06-quality/assets/remove-duplicate-search-2026-07-29/01-expert-team.png`
  - `/Users/cofe/IOS-IM/docs/06-quality/assets/expert-team-circle-2026-07-28/01-circle-feed.png`
  - `/Users/cofe/IOS-IM/docs/06-quality/assets/ui-audit-2026-07-28/18-settings.png`
- Rendered implementation:
  - `/Users/cofe/IOS-IM/docs/06-quality/assets/flutter/qa-round-2/implementation-conversations-round2.png`
  - `/Users/cofe/IOS-IM/docs/06-quality/assets/flutter/qa-round-2/implementation-experts-round2.png`
  - `/Users/cofe/IOS-IM/docs/06-quality/assets/flutter/qa-round-2/implementation-circle-round2.png`
  - `/Users/cofe/IOS-IM/docs/06-quality/assets/flutter/qa-round-2/implementation-settings-before.png`
- State: light appearance, populated mock data, primary tab root routes.

## Viewport and normalization

- Flutter simulator: iPhone 17 Pro, `402 × 874` logical points, `1206 × 2622` pixels, `@3x`.
- Conversation source crop: `320 × 670` pixels including the prototype device frame.
- Other source boards: `1280 × 720` pixels; the centered prototype phone is approximately `320 × 670` CSS pixels and includes the bezel.
- Comparison was based on the phone content and its relative logical measurements. Desktop canvas, browser rail, explanatory panels, device bezel, status-bar time, and source/implementation density differences were excluded from visual findings.

## Findings

No actionable P0, P1, or P2 mismatches remain in the four primary tab roots for this round.

- Typography: the Flutter tokens preserve the prototype's 22/16/15/13/12/10 point hierarchy, weights, line heights, truncation, and iOS system-font fallback. Differences caused only by the `@3x` simulator capture were ignored.
- Spacing and layout rhythm: navigation height, search field, 72-point conversation rows, 50-point avatars, section labels, card radii, bottom tab bar, and list dividers follow the HTML CSS contract.
- Colors and tokens: paper/soft backgrounds, accent blue, semantic green/amber/red/gray, market gradient, muted copy, divider opacity, and circle card shadows map to the prototype.
- Images and icons: visible expert portraits and circle gallery subjects use the same source URLs and crops; group avatars reproduce the source 2 × 2 composition. Visible UI icons use the bundled Phosphor font mappings used by the HTML prototype; the remaining Material image fallback was replaced.
- Copy and content: the same conversation states, expert names/statuses, circle result content, local-space settings, model count, and memory count are represented. “50 位专家” and five configured providers are intentional later product updates.

## Full-view comparison evidence

- Conversations: the post-fix implementation matches the source hierarchy and above-the-fold density; group avatars, sender emphasis, status tags, times, dividers, and unread badges occupy the expected regions.
- Expert team: the market entry, grouped expert rows, presence states, row density, portraits, and navigation match the source structure. The added “50 位专家” count is intentional product content.
- Circle: the first gallery, PDF result card, card actions, second schedule post, background, radii, and shadow hierarchy match the source.
- Settings: the enlarged local-space profile card, metrics, model-service rows, memory rows, icons, and fixed tab bar match the latest local-first product direction reflected in the HTML.

## Focused-region evidence

Focused comparisons were made for the conversation avatar/badge rows, expert market banner and row status dots, circle gallery/result card, and settings model-service rows. These regions were readable in the `1206 × 2622` simulator captures; no additional crop was required.

## Comparison history

1. Earlier finding: **[P0] group-avatar render failure and extreme horizontal overflow**.
   - Evidence: the first post-change widget run reported duplicate child keys in `HaloGroupAvatar` and a `RenderFlex` overflow.
   - Fix: assigned unique indexed keys to all four group-avatar tiles and retained a fixed `50 × 50` component contract.
   - Post-fix evidence: `/Users/cofe/IOS-IM/docs/06-quality/assets/flutter/qa-round-2/implementation-conversations-round2.png`; full test suite passed with no overflow exception.
2. Earlier finding: **[P2] conversation groups were represented by generic letter avatars and unread counts were attached to avatars**.
   - Fix: implemented the source 2 × 2 portrait/letter composition and moved unread badges to the trailing preview region.
   - Post-fix evidence: `/Users/cofe/IOS-IM/docs/06-quality/assets/flutter/qa-round-2/implementation-conversations-round2.png`.
3. Earlier finding: **[P2] expert rows and market entry were visually too generic and information-dense**.
   - Fix: restored the source gradient, icon slot, compact two-line expert rows, presence dots, dividers, and section grouping.
   - Post-fix evidence: `/Users/cofe/IOS-IM/docs/06-quality/assets/flutter/qa-round-2/implementation-experts-round2.png`.
4. Earlier finding: **[P1] circle posts omitted the defining gallery and result/status cards**.
   - Fix: added the source image triptych, PDF result card, schedule status, monitored-link card, and failure card using realistic fixture data.
   - Post-fix evidence: `/Users/cofe/IOS-IM/docs/06-quality/assets/flutter/qa-round-2/implementation-circle-round2.png`.

## Implementation checklist

- [x] Replace generic group avatars with source-style composite avatars.
- [x] Correct conversation unread and semantic-state placement.
- [x] Restore expert market banner and compact row hierarchy.
- [x] Restore rich circle post formats and realistic image data.
- [x] Keep the enlarged local-first profile and model-provider settings.
- [x] Remove the last direct Material icon fallback from visible feature UI.
- [x] Run Flutter tests and static analysis.
- [x] Capture and visually compare all four primary tab roots.

## Follow-up polish

- P3: capture exact same-time status bars when producing marketing screenshots; this does not affect the app UI.
- P3: repeat the same visual pass for secondary routes (chat detail, group detail, market detail, provider detail, media preview) in the next round.

final result: passed
