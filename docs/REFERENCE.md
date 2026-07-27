# 参考手册

本文列出 Codex Margin Float 的启动接口、窗口常量、本地数据来源和持久化设置。

## 启动入口

普通启动：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\src\CodexMarginFloat.ps1
```

Windows 用户也可以双击：

```text
Start-CodexMarginFloat.cmd
```

该启动器会检查主脚本是否存在，通过 `Start-Process` 创建隐藏且独立的 PowerShell 进程，并立即关闭命令行窗口；关闭启动窗口不会终止悬浮程序。

应用使用命名互斥锁 `Local\CodexMarginFloat.Singleton` 保证单实例运行。第二次启动通过 `Local\CodexMarginFloat.Activate` 自动重置信号唤醒已有窗口。

构建发布 EXE：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build-Package.ps1
```

默认先执行 Smoke Test，再通过 Windows .NET Framework CodeDOM 编译一个无控制台窗口的便携启动器。应用脚本以 Base64 形式内嵌，运行时按版本释放到 `%LOCALAPPDATA%\CodexMarginFloat\app`，最后在 `dist` 生成 `.exe` 与 `.exe.sha256`。

仓库的 `Windows Release` 工作流由 `v*` 标签触发，并校验标签必须等于 `v<VERSION>`。标签构建会创建或覆盖对应 GitHub Release 资产；手动触发只上传 Actions Artifact。

普通窗口设置 `WS_EX_TOOLWINDOW` 并移除 `WS_EX_APPWINDOW`，因此不会出现在 `Win+Tab`、`Alt+Tab` 或普通任务栏按钮中。应用入口位于 Windows 任务栏通知区域。

## 命令行参数

| 参数 | 类型 | 默认值 | 作用 |
|---|---|---|---|
| `-CheckData` | switch | 关闭 | 输出经过筛选的本地用量 JSON，不创建窗口 |
| `-CheckDeepSeekData` | switch | 关闭 | 输出固定 DeepSeek 余额映射并验证 DPAPI |
| `-CheckDeepSeekUsage` | switch | 关闭 | 输出本机 Claude Code DeepSeek Token 汇总 |
| `-CheckCodexRateLimitSelection` | switch | 关闭 | 验证并行会话按事件时间选择完整 Codex 限额 |
| `-CheckPlacement` | switch | 关闭 | 输出固定测试场景的屏幕避让结果 |
| `-CheckTransitions` | switch | 关闭 | 运行不可见的窗口状态回归并输出 JSON |
| `-Demo` | switch | 关闭 | 使用固定演示数据，不读取真实用量 |
| `-DemoProvider` | string | `codex` | 演示 `codex` 或 `deepseek` 视图 |
| `-RenderPreview` | string | 空 | 接受 `compact` 或 `expanded`，渲染 PNG 预览 |
| `-RenderDeepSeekSettingsPreview` | string | 空 | 接受 `unconfigured` 或 `configured`，渲染脱敏设置界面 |
| `-PreviewPath` | string | 空 | 指定预览 PNG 的输出路径 |

生成预览：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA `
  -File .\src\CodexMarginFloat.ps1 `
  -Demo -RenderPreview compact `
  -PreviewPath .\preview-compact.png
```

## 窗口常量

| 项目 | 值 |
|---|---:|
| 紧凑宽度 | 108 px |
| 紧凑高度 | 100 px |
| 详情宽度 | 370 px |
| 详情高度 | 500 px |
| 自动刷新间隔 | 60 秒 |
| 拖动阈值 | 5 px |
| 详情淡入 | 190 ms，系统关闭客户端动画时缩短为 1 ms |
| 通知区域图标 | 运行时绘制的 32×32 “C” 图标 |

窗口宽度和高度作为同一个状态原子切换，避免快速操作后落入 370×100 或 108×500 的部分尺寸。
进度条使用两列星号宽度：鼠尾草绿表示剩余比例，暖米灰表示已使用比例。
详情状态失去焦点时自动收起并恢复展开前的紧凑坐标；悬浮窗右键菜单打开期间不触发该行为。

## 数据字段

### Codex

应用从最新可用的 `token_count` 事件构造视图模型。

| 界面字段 | 本地来源 |
|---|---|
| 剩余百分比 | `100 - rate_limits.*.used_percent` |
| 已用额度 | `rate_limits.*.used_percent` |
| 周期标签 | `window_minutes` |
| 重置时间 | `resets_at` |
| 套餐 | `rate_limits.plan_type` |
| 今日 Token | 今日活跃本地会话的最新累计值之和 |
| 今日输入 Token | 今日会话 `total_token_usage.input_tokens` 之和 |
| 今日输出 Token | 今日会话 `total_token_usage.output_tokens` 之和 |
| 今日缓存 Token | 今日会话 `total_token_usage.cached_input_tokens` 之和 |
| 今日缓存命中率 | 今日缓存 Token ÷ 今日输入 Token |
| 账号名称与邮箱 | `auth.json` 中 ID Token 的对应声明 |

`Read-SessionSnapshot` 首先读取文件末尾 512KB。若尾部没有完整限额或 Token 统计，才从头逐行读取整个文件。快照按文件修改时间和长度缓存在进程内。

并行任务会同时写入不同 JSONL。文件修改时间只表示“文件刚被写过”，不等于限额的观测时间；应用因此按 `token_count.timestamp` 选择最新且同时包含 `used_percent`、`window_minutes` 和 `resets_at` 的限额事件。Token 汇总与限额快照分别选择，旧任务继续写日志时不会把过期的 100% 余量或重置时间覆盖到界面。

### DeepSeek

| 界面字段 | 来源 |
|---|---|
| 当前余额 | `/user/balance` 的 `total_balance` |
| 赠金余额 | `granted_balance` |
| 充值余额 | `topped_up_balance` |
| 可用状态 | `is_available` |
| 今日 Token | Claude Code JSONL 中 DeepSeek `message.usage` |
| 缓存 Token | `cache_read_input_tokens` |
| 当前模型 | DeepSeek 消息的 `model` |
| 预算百分比 | 当前余额 ÷ 用户设置的预算基准，限制在 0–100 |
| 本月累计 Token | 当月 Claude Code JSONL 中按 `message.id` 去重后的 Token |
| 本月累计花费 | 按模型、缓存命中、缓存未命中和输出 Token 估算的人民币花费 |

DeepSeek API Key 使用 `Authorization: Bearer` 发送到固定官方地址。网络读取异步进行，8 秒超时；401、429 和其他 HTTP 错误会显示可恢复提示。

本月花费只覆盖本机 Claude Code 日志，不等同于账户级账单。精确账单需要从 DeepSeek Platform 的 Usage 页面导出。

## 设置

设置保存在：

```text
%LOCALAPPDATA%\CodexMarginFloat\settings.json
```

格式：

```json
{
  "Left": 1200.0,
  "Top": 700.0,
  "Expanded": false,
  "Topmost": true,
  "Provider": "Codex"
}
```

`Expanded` 当前固定保存为 `false`，因此应用始终以紧凑状态启动。保存的坐标在窗口句柄创建后根据对应显示器的工作区域校正。

DeepSeek 配置单独保存在：

```text
%LOCALAPPDATA%\CodexMarginFloat\deepseek.json
```

该文件只包含 DPAPI 密文、密钥末四位提示和预算基准。`DEEPSEEK_API_KEY` 环境变量存在时优先使用且不会写入文件。

## 通知区域菜单

| 操作 | 行为 |
|---|---|
| 左键单击图标 | 唤醒现有窗口并打开详情 |
| 打开详情 | 唤醒现有窗口并展开 |
| 立即刷新 | 唤醒窗口并读取本地快照 |
| 数据源 | 在 Codex 与 DeepSeek 之间切换 |
| DeepSeek 设置 | 仅在当前数据源为 DeepSeek 时显示；配置加密 API Key 和可选预算基准 |
| 始终置顶 | 与悬浮窗右键菜单同步 |
| 退出 | 保存设置、移除图标并释放单实例资源 |

## 数据不可用行为

- 找不到会话快照：显示“等待数据”
- 无法解析账号：显示“账号信息暂不可用”
- 缺少重置时间：显示“暂无”
- 不完整 Codex 限额：跳过该事件并继续使用最新完整事件
- 单个损坏的 JSONL 行：跳过该行并继续寻找有效事件
- DeepSeek 未配置密钥：显示“等待配置”
- DeepSeek 网络失败：保留上次成功数据并显示失败原因
- DeepSeek 未设置预算：显示货币余额，不显示百分比进度

## 相关文档

- [快速开始](../README.md#快速开始)
- [架构说明](ARCHITECTURE.md)
- [贡献指南](../CONTRIBUTING.md)
