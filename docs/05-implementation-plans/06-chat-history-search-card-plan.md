# Chat History Search And Card Modes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current mixed settings-list history screen with a search-first view and date-grouped iOS card views.

**Architecture:** Keep the prototype in `prototype.html`, but introduce an explicit `historyViewState` with mutually exclusive `search-idle`, `search-results`, and `category-cards` modes. A single mock `historyItems` collection drives keyword result lists and category card renderers so that every preview still uses the existing media-preview actions.

**Tech Stack:** Static HTML, CSS, vanilla JavaScript, Node test runner, in-app browser QA.

## Global Constraints

- Entering “查找聊天记录” shows one search field and an otherwise blank content area.
- Search results are vertical list rows with highlighted keyword matches.
- Category entry points render date-grouped cards; only search results use list rows.
- The production mobile implementation uses SQLite FTS5; the HTML prototype emulates its result behavior in memory.
- Preserve existing Halo colors, Phosphor icons, preview actions, single-chat and group-chat return paths.

---

### Task 1: Search-first history shell

**Files:**
- Modify: `prototype.test.cjs`
- Modify: `prototype.html`

**Interfaces:**
- Produces: `historySearchInput`, `historyContent`, `historyViewState`
- Produces: `openHistory(category = 'search', returnPage = 'chat-details')`

- [ ] **Step 1: Write the failing test**

Add a test requiring `id="historySearchInput"`, `id="historyContent"`, `search-idle`, and the removal of the old `history-filter` and `historyResults` settings list.

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test --test-name-pattern='chat history opens in a search-only idle state' prototype.test.cjs`

Expected: FAIL because the new search shell does not exist.

- [ ] **Step 3: Implement the minimal search shell**

Replace the old filter chips and setting group with:

```html
<div class="history-search-wrap">
  <label class="history-search">
    <i class="ph ph-magnifying-glass"></i>
    <input id="historySearchInput" type="search" placeholder="搜索聊天记录">
    <button type="button" data-action="clear-history-search" aria-label="清除搜索">
      <i class="ph ph-x-circle"></i>
    </button>
  </label>
</div>
<div class="history-content" id="historyContent" data-history-mode="search-idle"></div>
```

Add an `input` listener that renders an empty content area for an empty query and a result list for a non-empty query.

- [ ] **Step 4: Run the focused test**

Run: `node --test --test-name-pattern='chat history opens in a search-only idle state' prototype.test.cjs`

Expected: PASS.

---

### Task 2: FTS-style highlighted result list

**Files:**
- Modify: `prototype.test.cjs`
- Modify: `prototype.html`

**Interfaces:**
- Consumes: `historySearchInput`, `historyContent`
- Produces: `historyItems`, `renderHistorySearchResults(query)`, `highlightHistoryMatch(text, query)`

- [ ] **Step 1: Write the failing test**

Add a test requiring the mock index fields `messageText`, `displayName`, `agentName`, `sourceTitle`, the `history-search-result` row, and `<mark class="history-match">`.

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test --test-name-pattern='history search renders highlighted list results' prototype.test.cjs`

Expected: FAIL because the indexed mock data and renderer are missing.

- [ ] **Step 3: Implement the result renderer**

Create at least ten mixed history items. Filter case-insensitively across:

```js
['messageText', 'displayName', 'agentName', 'sourceTitle']
```

Render matching items as full-width buttons with type icon, highlighted title/snippet, source, and date. Escape text before inserting `<mark>` tags. Reuse `data-preview-image`, `data-preview-file`, `data-preview-link`, or `data-action="inspect-rich-card"` so every result opens.

- [ ] **Step 4: Run the focused test**

Run: `node --test --test-name-pattern='history search renders highlighted list results' prototype.test.cjs`

Expected: PASS.

---

### Task 3: Date-grouped category cards and interaction QA

**Files:**
- Modify: `prototype.test.cjs`
- Modify: `prototype.html`

**Interfaces:**
- Consumes: `historyItems`
- Produces: `renderHistoryCards(category)`, `history-date-section`, category-specific card classes

- [ ] **Step 1: Write the failing test**

Add a test requiring date section headings and distinct `history-media-grid`, `history-file-grid`, `history-link-card`, and `history-artifact-card` render paths.

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test --test-name-pattern='history categories render date-grouped cards' prototype.test.cjs`

Expected: FAIL because category cards are missing.

- [ ] **Step 3: Implement category cards**

Group the selected dataset by `dateLabel`. Render media in a three-column square grid, files in a two-column card grid, and links/artifacts as full-width cards. Display the active category title in the navigation bar and expose a compact menu to switch categories without showing horizontal chips.

- [ ] **Step 4: Run all tests**

Run: `node --test prototype.test.cjs`

Expected: all tests pass.

- [ ] **Step 5: Browser verification**

Verify:

1. Search entry is blank until text is entered.
2. Query `竞品` produces highlighted list results.
3. Media, file, link, artifact, and all entry points produce date sections and cards.
4. Every card opens the correct preview.
5. No horizontal overflow or browser-width scrollbar exists.

Run: `curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:4173/prototype.html`

Expected: `200`.

