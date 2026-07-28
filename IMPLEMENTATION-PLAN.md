# IOS-IM Interactive Prototype Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a realistic, single-file, clickable HTML prototype for the personal AI-only iOS IM defined in `PRODUCT-DESIGN.md`.

**Architecture:** Copy the approved V4 prototype into `IOS-IM/prototype.html`, then extend its page-based state machine with group-chat screens, modal sheets, mutable mock state, and richer datasets. Keep the artifact build-free and self-contained except for remote mock images, while providing a Node test that verifies required screens, controls, and content contracts.

**Tech Stack:** HTML5, CSS, vanilla JavaScript, Node.js built-in test runner.

## Global Constraints

- All deliverables live under `/Users/cofe/office Lady/IOS-IM`.
- The prototype is personal-only and contains no human social contacts.
- The bottom navigation has exactly four tabs: 对话、通讯录、AI 朋友圈、设置.
- Group chat is text-only; voice and video remain one-to-one Agent features.
- Group chat includes automatic selection, `@Agent`, and `@所有人` / discussion modes.
- Every visible interactive element provides navigation, state change, sheet, or toast feedback.
- Each main page contains at least three distinct mock content types.
- Use familiar IM structure without WeChat trademarks, icons, green brand color, or pixel-identical styling.

---

### Task 1: Establish the Prototype Contract

**Files:**
- Create: `IOS-IM/prototype.test.cjs`
- Read: `IOS-IM/PRODUCT-DESIGN.md`
- Read: `IOS-IM/PROTOTYPE-PLAN.md`

**Interfaces:**
- Consumes: the page and interaction requirements in the two specification files.
- Produces: a Node test suite that reads `IOS-IM/prototype.html` and asserts required page IDs, copy, controls, mock types, and the absence of group-call controls.

- [ ] **Step 1: Write the failing structure tests**

Create tests for the four main tabs, three named group chats, `group-chat`, `group-info`, `new-group`, the three reply modes, mixed mock content, market interactions, Moments content, and settings data.

- [ ] **Step 2: Run tests and verify RED**

Run: `node --test IOS-IM/prototype.test.cjs`

Expected: FAIL because `IOS-IM/prototype.html` does not exist.

- [ ] **Step 3: Commit the contract**

Run:

```bash
git add IOS-IM/prototype.test.cjs IOS-IM/IMPLEMENTATION-PLAN.md
git commit -m "test: define IOS-IM prototype contract"
```

### Task 2: Migrate and Restructure the Existing Prototype

**Files:**
- Create: `IOS-IM/prototype.html`
- Source: `.superpowers/brainstorm/62868-1785223698/content/ios-interactive-prototype-v4.html`
- Modify: `IOS-IM/prototype.test.cjs`

**Interfaces:**
- Consumes: the approved V4 visual language and `data-go` page navigation convention.
- Produces: a standalone prototype shell with all main and secondary page containers.

- [ ] **Step 1: Copy the existing approved HTML**

Copy V4 to `IOS-IM/prototype.html` as the visual and interaction baseline.

- [ ] **Step 2: Add all required page shells**

Add page containers for `group-chat`, `group-info`, `new-group`, and `group-context`. Add direct left-rail navigation entries for the three group-chat examples.

- [ ] **Step 3: Remove group-call affordances**

Ensure the group header contains search, group information, and more actions, with no voice or video buttons.

- [ ] **Step 4: Run contract tests**

Run: `node --test IOS-IM/prototype.test.cjs`

Expected: structure assertions pass; behavior assertions may remain failing until Task 3.

### Task 3: Implement the Three Group Reply Modes

**Files:**
- Modify: `IOS-IM/prototype.html`
- Modify: `IOS-IM/prototype.test.cjs`

**Interfaces:**
- Consumes: group members and reply-mode controls declared in the HTML.
- Produces: `setGroupMode(mode)`, `runGroupReply(mode)`, `stopDiscussion()`, and visible mode/stage state.

- [ ] **Step 1: Add failing behavior-contract assertions**

Assert the presence of the three function names, explicit modes `auto`, `mention`, `all`, a stop control, a sequential discussion timeline, and a generated summary card.

- [ ] **Step 2: Run tests and verify RED**

Run: `node --test IOS-IM/prototype.test.cjs`

Expected: FAIL on missing mode functions.

- [ ] **Step 3: Implement automatic selection**

Normal send shows “自动选择 1–2 个合适的 Agent”, appends the user message, then sequential mock replies from the selected Agent pair.

- [ ] **Step 4: Implement mention selection**

The `@` control opens a member sheet; selecting members updates the composer hint and sends the message only to selected Agents.

- [ ] **Step 5: Implement full discussion**

The discussion control moves through 观点收集 → 交叉讨论 → 总结, appends sequential Agent messages with one explicit rebuttal, and ends with a summary card.

- [ ] **Step 6: Implement stop**

The stop control cancels pending mock timers and appends a “讨论已停止” system state.

- [ ] **Step 7: Run tests and verify GREEN**

Run: `node --test IOS-IM/prototype.test.cjs`

Expected: all group interaction contract tests pass.

### Task 4: Expand Mock Data and Mutable Interactions

**Files:**
- Modify: `IOS-IM/prototype.html`
- Modify: `IOS-IM/prototype.test.cjs`

**Interfaces:**
- Consumes: existing pages and generic bottom-sheet/toast helpers.
- Produces: richer data across every main page plus functional group creation, Agent addition, settings, and Moments actions.

- [ ] **Step 1: Add failing data-density assertions**

Assert at least three content families per main page and the required group/market/settings action labels.

- [ ] **Step 2: Run tests and verify RED**

Run: `node --test IOS-IM/prototype.test.cjs`

Expected: FAIL on missing mock content or action labels.

- [ ] **Step 3: Expand the conversation list**

Add one-to-one, three group-chat types, system progress, file completion, image preview, failure, unread, muted, and pinned examples.

- [ ] **Step 4: Expand contacts and market**

Add multiple categories, availability states, model labels, permissions, pricing/use hints, Add to Contacts, and Add to Group flows.

- [ ] **Step 5: Expand Moments**

Add image grid, PDF, source links, data card, weekly summary, failed task, privacy marker, Agent comments, and “return to source chat”.

- [ ] **Step 6: Expand settings**

Add account/sync, memory, model usage, calls, notification, permissions, security, and legal/model information groups with interactive sheets and toggles.

- [ ] **Step 7: Implement mutable flows**

Creating a group adds it to the conversation list; adding an Agent updates Contacts; adding an Agent to a group updates group info; publishing a summary adds a Moments post.

- [ ] **Step 8: Run tests and verify GREEN**

Run: `node --test IOS-IM/prototype.test.cjs`

Expected: all tests pass.

### Task 5: Visual and Interaction Verification

**Files:**
- Verify: `IOS-IM/prototype.html`
- Verify: `IOS-IM/prototype.test.cjs`
- Update: `IOS-IM/README.md`

**Interfaces:**
- Consumes: final static artifact.
- Produces: verified desktop and narrow-screen prototype plus updated launch instructions.

- [ ] **Step 1: Run the full automated suite**

Run:

```bash
node --test IOS-IM/prototype.test.cjs
git diff --check -- IOS-IM
```

Expected: zero failures and zero whitespace errors.

- [ ] **Step 2: Serve the prototype locally**

Run: `python3 -m http.server 8765 --directory IOS-IM`

Open: `http://127.0.0.1:8765/prototype.html`

- [ ] **Step 3: Visually inspect desktop**

Verify the phone frame, rail navigation, all required pages, overflow behavior, group reply modes, sheets, and toast placement.

- [ ] **Step 4: Visually inspect narrow viewport**

Verify at 430×932 that the prototype remains usable, controls do not overlap, and horizontal overflow is absent.

- [ ] **Step 5: Update handoff instructions**

Document how to open the HTML directly or via the local server in `IOS-IM/README.md`.

- [ ] **Step 6: Commit the prototype**

Run:

```bash
git add IOS-IM
git commit -m "feat: build interactive IOS-IM prototype"
```
