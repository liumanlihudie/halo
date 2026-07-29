# Flutter Visual QA — Round 3

## Target and evidence

- Visual source of truth: `/Users/cofe/IOS-IM/prototype.html`
- Reference captures: `/Users/cofe/IOS-IM/docs/06-quality/assets/ui-audit-2026-07-28/`
- Flutter captures before the final corrections:
  `/Users/cofe/IOS-IM/docs/06-quality/assets/flutter/qa-round-3/`
- Flutter captures after the final corrections:
  `/Users/cofe/IOS-IM/docs/06-quality/assets/flutter/qa-round-3-final/`
- Device: iPhone 17 Pro simulator, `402 × 874` logical points, light mode,
  populated mock state.

The reference and Flutter render were inspected together for each corrected
screen. Browser rails, device bezels, status-bar time, and capture scaling were
excluded from findings.

## Result

No actionable P0, P1, or P2 mismatches remain in the checked primary and
secondary prototype flows.

- Navigation titles stay centered and use a white navigation surface.
- Scrollable content uses the prototype soft background with no horizontal
  scrollbar.
- Chat and group title badges preserve the compact inline layout.
- Chat details, group information, shared context, and group creation use the
  prototype row density, inset cards, section labels, portraits, and controls.
- Voice and video calls remain in the chat `+` menu and in expert profile
  actions; they are not duplicated in the chat header.
- Expert profile now uses the same photographic hero, portrait, description,
  icon-free setting rows, compact switches, and complete preference group as
  the HTML.
- Switches use the prototype `43 × 25` geometry and toggle interactively.
- The existing Phosphor icon mapping remains the single visible icon source.

## Corrections made in this round

1. **[P1] Secondary headers inherited the soft body color.**
   The scaffold now separates the paper navigation surface from the selected
   body surface.
2. **[P1] Expert profile used an invented navy letter-avatar hero and omitted
   source controls.**
   It now resolves `general-assistant` to the fixture expert, uses the source
   hero/portrait, and restores proactive messages, circle publishing, and add
   to group.
3. **[P2] Group information used placeholder members and stopped before the
   lower management sections.**
   It now restores the four-member strip, asset shortcuts, current-group
   settings, export, clear, and delete areas.
4. **[P2] New-group and shared-context screens diverged from the HTML content.**
   Both were rebuilt from the current source labels, selected members, access
   states, and isolation policy.
5. **[P2] Settings used oversized platform-adaptive switches.**
   All corrected screens now share the measured prototype switch.

## Verification

- `flutter analyze`: passed.
- `flutter test --reporter compact`: 30 tests passed.
- Route contract: all 23 HTML prototype pages have Flutter routes.
- Backend gateway: 7 contract tests passed; Ruff check and format passed.
- `git diff --check`: passed.

final result: passed
