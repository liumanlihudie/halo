# Design QA — 群聊底部安全区

- Source visual truth: `/Users/cofe/office Lady/IOS-IM/qa-reference-bottom-clipping.png`
- Implementation screenshot: `/Users/cofe/office Lady/IOS-IM/qa-group-chat.png`
- Combined focused comparison: `/Users/cofe/office Lady/IOS-IM/qa-bottom-comparison.png`
- Browser viewport: `1920 × 882` CSS px, device scale factor 1
- Source pixels: `816 × 394`
- Implementation pixels: `1920 × 882`; rendered phone frame `381 × 826` after responsive scale
- State: “iOS 产品小组”群聊，默认自动选择模式

## Full-view comparison evidence

The browser-rendered phone frame fits entirely inside the available viewport. Its measured bounds are `y=41` through `y=867`, within the `882px` viewport. The composer ends at the inner edge of the phone frame rather than outside it.

## Focused comparison evidence

`qa-bottom-comparison.png` places the reported bottom crop beside the revised implementation crop. The revised composer, input field, @ button, send button, rounded screen corners, and bottom bezel are all visible. No persistent control is clipped.

## Fidelity surfaces

- Fonts and typography: Existing SF/PingFang system stack, weights, wrapping, and hierarchy are unchanged.
- Spacing and layout rhythm: Added a 30px simulated iOS bottom safe area. Message-list bottom padding now follows the measured composer height and expands from `148px` to `210px` when the discussion progress panel appears.
- Colors and visual tokens: Existing accent, neutral surfaces, borders, and opacity are unchanged.
- Image quality: Existing avatar crops and source imagery are unchanged. The combined comparison is enlarged only for inspection.
- Copy and content: Existing chat content and control labels are unchanged.
- Icons: Existing Phosphor icon family and sizing are unchanged.
- Responsiveness: The `393 × 852` phone frame now scales to the available desktop stage height; the mobile full-viewport mode remains unscaled.
- Interactions: Opened the group chat, selected “@某个 Agent”, chose “技术架构师”, started and stopped “让大家讨论”, and verified composer inset updates.
- Console: No browser console errors.

## Comparison history

1. Earlier P1 finding: fixed-height phone could extend beyond a short browser viewport, making the bottom appear cut off.
   - Fix: scale the phone frame against available stage width and viewport height.
   - Post-fix evidence: phone bottom is `867px` in an `882px` viewport.
2. Earlier P1 finding: chat history reserved a fixed `112px`, while the group composer changes height.
   - Fix: measure each visible composer with `ResizeObserver` and apply its height plus `12px` as the scroll inset.
   - Post-fix evidence: default group composer uses `148px`; expanded discussion state uses `210px`.
3. Earlier P2 finding: input controls sat too close to the simulated device corner.
   - Fix: use a `30px` phone bottom safe-area token.
   - Post-fix evidence: all bottom controls and rounded corners are visible in the focused comparison.

## Follow-up polish

No remaining P0, P1, or P2 issue was found in the reported state. Desktop scaling can make the phone appear slightly smaller on short windows; this is intentional to preserve the full device frame.

final result: passed
