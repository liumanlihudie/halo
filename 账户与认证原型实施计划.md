# Halo iOS 账户与认证原型 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有单文件 HTML 原型中实现可点击的账户、安全、登录与 Token 充值完整演示闭环。

**Architecture:** 继续使用 `prototype.html` 的 page-based 本地状态机与事件委托，不引入构建系统或后端。账户、认证、验证码、密码重置与 Token 支付使用独立页面，共享少量内存状态和渲染函数；自动化测试验证页面契约、状态转换和关键交互。

**Tech Stack:** HTML5、CSS、原生 JavaScript、Phosphor Icons、Node.js `node:test`、本地静态 HTTP 服务。

## Global Constraints

- 所有文件继续放在 `IOS-IM`。
- 保持现有四个主标签页、现有 mock 数据和对话功能。
- 登录前页面不显示四栏主导航，登录成功后回到对话页。
- 所有新增图标使用现有 Phosphor 图标库。
- 不接真实后端、短信、邮件、Apple 登录或支付。
- 页面标题居中，无横向滚动条，无底部裁切。
- 危险操作二次确认；表单错误显示在字段附近。

---

### Task 1: 设置入口与账户页面骨架

**Files:**
- Modify: `IOS-IM/prototype.html`
- Test: `IOS-IM/prototype.test.cjs`

**Interfaces:**
- Consumes: 既有 `showPage(pageId)`、`data-go` 导航、`.page`、`.setting-group`。
- Produces: 页面 ID `account-center`、`change-password`、`switch-account`、`token-center`、`token-checkout`、`token-result`。

- [ ] **Step 1: Write the failing test**

新增测试，读取原型并断言设置页包含 `data-go="account-center"`、`data-go="token-center"`、`data-go="change-password"`、`data-go="switch-account"` 和 `data-action="logout"`；同时断言六个页面 ID 存在。

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test IOS-IM/prototype.test.cjs`

Expected: FAIL，缺少账户入口或页面。

- [ ] **Step 3: Write minimal implementation**

在设置页增加「账户与安全」「Token 与支付」分组及红色退出入口；增加六个独立页面，统一使用紧凑导航、`ios-scroll` 和现有安全区。

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test IOS-IM/prototype.test.cjs`

Expected: PASS。

### Task 2: 登录、验证码与密码流程

**Files:**
- Modify: `IOS-IM/prototype.html`
- Test: `IOS-IM/prototype.test.cjs`

**Interfaces:**
- Consumes: `showPage(pageId)`、`showToast(message)`、`openSheet(title, content)`。
- Produces: 页面 ID `login`、`verification-login`、`forgot-password`；函数 `submitPasswordLogin()`、`sendVerificationCode()`、`submitVerificationLogin()`、`advancePasswordReset()`、`submitPasswordChange()`。

- [ ] **Step 1: Write the failing test**

新增测试，断言三种认证页面存在；测试执行原型脚本后调用上述函数，验证空输入出现字段错误、六位验证码可登录、忘记密码完成后返回登录页、新密码不一致时不提交。

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test IOS-IM/prototype.test.cjs`

Expected: FAIL，认证页面或函数未定义。

- [ ] **Step 3: Write minimal implementation**

增加认证品牌头、带标签的输入框、密码可见性、六位验证码输入、错误提示和主次按钮；实现验证码倒计时 mock、登录成功状态、三步忘记密码和修改密码校验。

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test IOS-IM/prototype.test.cjs`

Expected: PASS。

### Task 3: 账号切换与退出登录

**Files:**
- Modify: `IOS-IM/prototype.html`
- Test: `IOS-IM/prototype.test.cjs`

**Interfaces:**
- Consumes: `accountState`、`showPage(pageId)`、`openSheet(title, content)`。
- Produces: `switchAccount(accountId)`、`confirmLogout()`、`completeLogout()`、动态资料卡渲染。

- [ ] **Step 1: Write the failing test**

新增测试，断言账号切换页包含三个 mock 账号与「登录其他账号」；调用切换函数后当前账号和设置资料同步变化；退出操作先展示确认内容，确认后进入 `login`。

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test IOS-IM/prototype.test.cjs`

Expected: FAIL，账号状态或退出流程不存在。

- [ ] **Step 3: Write minimal implementation**

定义当前账号与两个最近账号；渲染账号卡，点击其他账号模拟 Face ID 后切换；退出登录打开危险确认弹层，确认后隐藏主标签并进入登录页。

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test IOS-IM/prototype.test.cjs`

Expected: PASS。

### Task 4: Token 余额、充值与交易记录

**Files:**
- Modify: `IOS-IM/prototype.html`
- Test: `IOS-IM/prototype.test.cjs`

**Interfaces:**
- Consumes: `showPage(pageId)`、`showToast(message)`。
- Produces: `tokenState`、`selectTokenPack(packId)`、`selectPaymentMethod(methodId)`、`submitTokenPayment(outcome)`、`renderTokenState()`。

- [ ] **Step 1: Write the failing test**

新增测试，断言 Token 中心展示余额、三种套餐、三种支付方式与四类交易；调用成功支付后余额增加并显示成功结果，失败支付不增加余额并提供重试。

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test IOS-IM/prototype.test.cjs`

Expected: FAIL，Token 状态或充值流程不存在。

- [ ] **Step 3: Write minimal implementation**

实现 Token 余额英雄卡、用途估算、套餐选择、自定义充值入口、支付方式、确认订单、处理中与成功/失败结果页；成功后把交易写入最近记录。

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test IOS-IM/prototype.test.cjs`

Expected: PASS。

### Task 5: 视觉回归、文档与服务验证

**Files:**
- Modify: `IOS-IM/DEVELOPMENT-GUIDE.md`
- Modify: `IOS-IM/TECHNICAL-DESIGN.md`
- Modify: `IOS-IM/design-qa.md`
- Test: `IOS-IM/prototype.test.cjs`

**Interfaces:**
- Consumes: Tasks 1–4 的全部页面和交互。
- Produces: 浏览器 QA 记录、更新后的开发与技术说明。

- [ ] **Step 1: Run automated verification**

Run: `node --test IOS-IM/prototype.test.cjs`

Expected: 所有测试 PASS。

- [ ] **Step 2: Run syntax and whitespace checks**

Run: `node -e "const fs=require('fs'),vm=require('vm');const h=fs.readFileSync('IOS-IM/prototype.html','utf8');const s=h.match(/<script>([\\s\\S]*)<\\/script>/)[1];new vm.Script(s);console.log('script syntax ok')"`

Run: `git diff --check -- IOS-IM`

Expected: 两条命令 exit 0。

- [ ] **Step 3: Browser walkthrough**

在 `http://127.0.0.1:4173/prototype.html` 依次验证：

1. 设置 → Token 中心 → 套餐 → 支付成功。
2. 设置 → 切换账号 → 选择最近账号。
3. 设置 → 修改密码 → 不一致错误 → 成功。
4. 设置 → 退出登录 → 取消 → 再次退出确认。
5. 密码登录、验证码登录、忘记密码三步流程。

确认每页无横向滚动条、标题居中、底部内容不裁切、控制台无错误。

- [ ] **Step 4: Update documentation**

在开发文档中补充演示路径；在技术文档中补充 `authState`、`accountState`、`tokenState` 和真实实现边界；在 QA 文档记录检查结果。

- [ ] **Step 5: Final verification and commit**

Run: `node --test IOS-IM/prototype.test.cjs && git diff --check -- IOS-IM`

Expected: exit 0。

Commit:

```bash
git add IOS-IM/prototype.html IOS-IM/prototype.test.cjs IOS-IM/DEVELOPMENT-GUIDE.md IOS-IM/TECHNICAL-DESIGN.md IOS-IM/design-qa.md IOS-IM/账户与认证原型实施计划.md
git commit -m "feat: add account auth and token flows"
```
