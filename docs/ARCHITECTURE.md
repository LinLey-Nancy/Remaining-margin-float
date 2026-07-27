# 架构说明

Codex Margin Float 是一个单文件 PowerShell/WPF 桌面应用。它的目标是用最少依赖展示 Codex 与 DeepSeek 用量，同时保持窗口状态稳定、数据来源透明。

## 数据流

```text
Codex JSONL ──> Get-CodexUsageSnapshot ─┐
                                        ├──> Update-UsageView ──> 紧凑 / 详情
DeepSeek API ─> ConvertTo-DeepSeekSnapshot
Claude JSONL ─> Get-DeepSeekLocalUsage ─┘
```

Codex Provider 不发起网络请求。DeepSeek Provider 使用固定官方地址异步查询余额；Claude Code JSONL 只用于本机 Token 统计。两个 Provider 输出同一视图模型，界面不直接依赖上游协议。

## DeepSeek 刷新

`HttpClient.SendAsync` 在 UI 线程外等待网络。现有一秒 Dispatcher Timer 只轮询任务完成状态，因此请求超时或网络缓慢不会阻塞拖动、展开和收起。请求超时为 8 秒；失败时保留上次成功快照并显示错误原因。

切换回 Codex 时会取消未完成的 DeepSeek 请求，再更新 Provider 状态和界面，防止旧请求覆盖新数据源。

Claude Code 日志在单文件解析和统计周期全局汇总两层按 `message.id` 去重，因为同一 DeepSeek 响应可能在一个或多个 JSONL 中重复出现。完整文件由编译型字段提取器读取，解析结果再按文件修改时间和长度缓存在进程内。

本月累计花费使用日志中的缓存命中、缓存未命中和输出 Token，按 DeepSeek V4 当前官方人民币单价估算。它是本机视图，不是账户账单；价格变化或其他设备/API Key 的调用不会自动反映在历史估算中。

## 为什么使用 PowerShell 和 WPF

这个项目面向 Windows 桌面，并要求轻量、免安装。Windows PowerShell 5.1 和 WPF 在受支持的 Windows 版本中已经存在，因此用户只需要双击启动脚本。

代价是 UI、数据读取和生命周期代码集中在一个 `.ps1` 文件中。该结构降低了分发成本，但不适合需要跨平台支持或大型插件系统的产品。

## 单实例与唤醒

首个进程创建：

- 命名互斥锁 `Local\CodexMarginFloat.Singleton`
- 自动重置信号 `Local\CodexMarginFloat.Activate`

后续进程发现互斥锁已存在后，不创建 WPF 窗口，而是设置激活信号并退出。首个实例每 180ms 非阻塞检查一次信号，收到后执行以下操作：

1. 将窗口校正到当前显示器的可见区域。
2. 恢复正常窗口状态。
3. 临时提升层级并激活窗口。
4. 恢复用户原来的置顶偏好。

这种实现不需要端口、管道或临时文件，也不会产生第二个可见窗口。

## 任务切换器与通知区域

`ShowInTaskbar=false` 只能隐藏普通任务栏按钮，不能保证透明无边框 WPF 窗口退出任务视图。窗口创建句柄后，应用追加 `WS_EX_TOOLWINDOW` 并移除 `WS_EX_APPWINDOW`，使悬浮窗不再出现在 `Win+Tab` 和 `Alt+Tab`。

应用使用 `System.Windows.Forms.NotifyIcon` 提供通知区域入口。图标在内存中绘制为 32×32 的鼠尾草绿色 “C”，不需要额外图片文件。关闭窗口时会依次隐藏并释放 NotifyIcon、菜单和 Icon 对象，避免退出后留下失效图标。

## 窗口状态

窗口只有两个合法尺寸：

```text
Compact  = 108 × 100
Expanded = 370 × 500
```

宽度和高度同步赋值，不分别运行动画。之前的独立尺寸动画在快速反向操作时可能落入部分状态，例如 370×100。当前实现只让详情内容淡入，窗口尺寸始终保持合法组合。

展开前会记录紧凑窗口坐标。详情窗口先根据当前显示器工作区域向左或向上避让；收起时恢复记录的坐标并清除锚点。

展开状态下，窗口的 `Deactivated` 事件会在 UI 空闲优先级再次检查焦点；确认窗口已失焦后立即切回紧凑状态。延迟检查用于区分真实的桌面/应用切换与 WPF 右键菜单建立弹出窗口时的瞬时焦点变化，菜单打开期间不会误收起。

## 日志读取策略

Codex 会话日志可能增长到几十 MB。每分钟完整读取所有文件会让 WPF UI 短暂停顿，因此读取器采用两级策略：

1. 从文件末尾读取最多 512KB，并寻找最后一个 `token_count` 事件。
2. 只有尾部没有有效事件时才逐行扫描整个文件。

缓存键由文件的 UTC 修改时间刻度和长度组成。文件没有变化时，下一次刷新直接复用解析结果。

取舍：首次读取或异常日志仍可能触发全量扫描，但正常的每分钟刷新只读取发生变化的文件尾部。

## 安全边界

- Codex 模式不发起网络请求；DeepSeek 模式只请求 `https://api.deepseek.com/user/balance`。
- 不执行会话文件中的内容。
- JSONL 只通过 `ConvertFrom-Json` 解析。
- ID Token 只解码载荷以显示名称和邮箱，不用于身份验证。
- 不显示、记录或持久化 access token、refresh token。
- DeepSeek API Key 使用 DPAPI `CurrentUser` 加密；界面只显示末四位。
- 不读取 CC Switch 数据库、配置或密钥。
- 通用设置文件只包含窗口坐标、置顶偏好和当前 Provider。

本应用读取的是当前用户有权访问的本地 Codex 文件。它不是认证组件，不能用解码后的 JWT 声明作安全决策。

## 相关文档

- [参考手册](REFERENCE.md)
- [快速开始](../README.md#快速开始)
- [贡献指南](../CONTRIBUTING.md)
