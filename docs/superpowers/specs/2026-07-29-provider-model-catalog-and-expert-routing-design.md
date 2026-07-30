# Provider 模型目录与专家模型路由设计

日期：2026-07-29

## 目标

移除生产代码中的固定模型 ID。用户保存 Provider API Key 时，Halo 自动获取并持久化该 Provider 返回的全部模型。用户可从已保存的模型中选择全局默认模型，并可在每位专家的人物资料页选择“跟随全局默认”或单独指定模型。

## 产品行为

### Provider 配置

- Provider 详情页只负责服务地址、API Key、启用状态和模型目录状态。
- 页面不再提供手工填写“模型 ID”的输入框。
- 点击保存后，应用使用刚写入 Keychain 的凭证调用 Provider 模型目录接口。
- 成功时保存服务配置和全部模型，并显示“已获取 N 个模型”。
- 模型按 `providerId + modelId` 唯一标识，去重后完整保存，不只保存一个推荐模型。
- 获取失败、响应非法或返回空目录时，整次保存失败；原配置、原 Key、原模型目录和原模型绑定继续有效。
- 用户可在 Provider 详情页主动刷新模型目录。刷新同样采用完整替换，不允许部分目录覆盖旧目录。

### 全局默认模型

- “设置 → 模型服务 → 全局默认模型”从所有已启用 Provider 的已保存模型中选择。
- 首次保存 Provider 不隐式挑选默认模型。没有默认模型时，聊天入口明确提示用户选择。
- 选择后持久化 `ModelRef(providerId, modelId)` 并热重载运行时。

### 专家模型

- 已安装专家的人物资料页增加“模型”设置项。
- 设置项支持：
  - 跟随全局默认；
  - 单独指定任一已启用 Provider 的已保存模型。
- “跟随全局默认”通过删除该专家的 override 实现，而不是复制当前默认值。
- 独立模型通过 `agentId -> ModelRef` 持久化。
- 模型选择变化后热重载运行时；下一条消息使用新模型，已发送消息不重跑。
- AI 市场中尚未安装的专家只展示建议模型，不写入本地 override。

## 数据模型

Provider 配置数据库升级到 schema v4，新增持久模型目录：

- `provider_models`
  - `provider_id`
  - `model_id`
  - `display_name`
  - 文字、system message、temperature、最大输出 token 等能力字段
  - `discovered_at`
- 主键：`provider_id + model_id`
- 外键：`provider_id` 指向 Provider 配置。

Provider 配置、模型目录和受影响的模型绑定必须在同一 SQLite 事务中提交。v3 到 v4 使用受测的增量迁移，保留现有 Provider 配置和 Keychain 引用。

模型目录刷新时：

- 仍存在的全局默认和专家 override 保留；
- 已不存在的全局默认清空；
- 已不存在的专家 override 清除，使专家回到“跟随全局默认”；
- 不允许无效绑定阻止整个生产运行时启动。

## 运行时与网络

- 为 OpenAI-compatible Provider 实现生产模型目录请求：`GET <baseUri>/models`。
- DeepSeek 使用 `https://api.deepseek.com/v1/models`。
- ToAPIs 使用 `https://toapis.com/v1/models`。
- 请求继续经过现有 DNS、TLS、SNI、重绑定和凭证脱敏安全策略。
- 模型目录响应经过现有 `ModelCatalogDiscovery` 的数量、ID、显示名和能力校验。
- 生产运行时从 SQLite 模型目录加载，不再由 `_loadProductionModels` 返回固定列表。
- Provider 返回的能力信息缺失时，只启用当前可以确定支持的文字能力；不虚构图片、视频或工具能力。

## 保存事务

保存 Key 的顺序：

1. 生成新的 canonical Keychain `SecretRef`。
2. 将 Key 写入 Keychain。
3. 使用新配置和新凭证获取模型目录。
4. 在 Provider SQLite 中 staged replace 配置、完整模型目录和仍有效的绑定。
5. 热重载生产运行时。
6. 成功后 finalize，并清理旧 Key。

任何一步失败都按现有 staged mutation 规则回滚。模型目录和 Key 不得写入聊天数据库、日志或错误消息。

## 界面

- Provider 详情页：
  - 删除“默认模型 ID”输入框；
  - 增加模型目录摘要；
  - 保存按钮文案在请求期间显示“正在验证并获取模型…”；
  - 配置成功后显示模型数量和最近更新时间；
  - “刷新模型目录”在已配置时可点击。
- 模型服务首页：
  - “默认文字模型”展示 `Provider / 模型名`；
  - 点击打开可搜索的模型选择页或底部选择器。
- 专家人物页：
  - “专家与动态”区域增加“模型”行；
  - detail 显示“跟随默认 · 当前模型”或“独立 · Provider / 模型名”；
  - 点击进入同一模型选择器，顶部多一个“跟随全局默认”选项。

## 错误与降级

- API Key 无效：显示固定安全错误“API Key 无效，未保存配置”。
- 模型接口不可用：显示“无法获取模型列表，原配置未变”。
- 模型目录为空或非法：拒绝保存，不允许用户手填一个 ID 绕过。
- 已选择模型被服务商移除：清除失效绑定；全局无默认时聊天 fail closed，专家 override 失效时回到跟随默认。
- 无配置、无目录或无默认模型时，聊天入口提供跳转到模型设置的操作。

## 验收

- 保存 DeepSeek Key 后自动获取并保存所有返回模型。
- 杀进程重启后模型目录仍存在。
- Provider 页面没有可手填模型 ID。
- 全局默认可在已保存模型中选择并影响未覆盖专家。
- 任一已安装专家可切换为独立模型，再切回跟随默认。
- 模型目录变化不会留下指向不存在模型的绑定。
- 获取失败不会破坏旧配置、旧目录、旧绑定或旧 Key。
- focused 测试、全量 Flutter 测试、`flutter analyze`、模拟器真实 DeepSeek 模型获取和单聊全部通过后才进入 iPhone 安装。
