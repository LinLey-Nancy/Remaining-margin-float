# Remaining Margin Float

一个轻量、浅色、可拖动的 Windows Codex / DeepSeek 余量悬浮窗。紧凑状态只显示当前数据源最重要的数字，点击后展开账户、余额或额度、Token 统计和数据采样时间。

项目只依赖 Windows PowerShell 5.1 与 WPF。Codex 模式默认读取本地 Codex
会话中的最近余量快照并汇总 Token；用户明确启用后，才会优先从官方账户用量
接口读取周期额度。DeepSeek 模式向官方余额接口发起请求，并从 Claude Code
本地日志汇总 DeepSeek Token。应用不会输出访问令牌。

## 功能

- Codex 与 DeepSeek 双数据源，可从悬浮窗或通知区域菜单切换
- 80×80 正方形紧凑悬浮窗：Codex 显示周期余量，DeepSeek 显示余额或预算百分比
- 可选贴边隐藏：拖到屏幕左侧或右侧后自动吸附，只保留贴边的 14px 竖向能量条触发区
- 贴边后悬停会以滑动动画展示紧凑布局，移开后自动滑回超紧凑布局
- 常规界面使用低饱和连续色阶；贴边能量条使用带完整四边微圆角描边的高亮纵向阈值渐变，从顶部充足绿过渡到中段琥珀和底部警戒红，并按物理像素紧贴屏幕边缘
- 双色进度条：鼠尾草绿表示剩余，暖米灰表示已使用
- 详情进度条上方右对齐显示下次重置日期与倒计时
- Codex 详情使用已用额度、今日 Token、今日缓存和今日输出，不展示并行任务下易失真的“本轮”指标
- 点击展开 370×500 详情，收起后恢复原始位置
- 详情展开后点击桌面或切换到其他应用会自动收起
- 展开时自动避让当前显示器边界
- 每 60 秒刷新，支持手动刷新
- 单实例运行，重复启动会唤醒已有窗口
- 不出现在 `Win+Tab` / `Alt+Tab`，通过任务栏通知区域图标访问
- 鼠标悬浮光效、拖动、键盘快捷键和系统减少动画设置
- 托盘与悬浮窗右键菜单可同步开关贴边隐藏
- 可选择计划任务、注册表或启动文件夹三种开机启动方式
- Codex 余量采用双通道：默认读取本地会话；用户明确启用官方接口后优先使用官方数据，网络不可用时回退到本地快照
- 官方接口在后台异步刷新，不会阻塞悬浮窗；两个通道均无数据时显示“余量未知”，不再误显示为 0%
- 读取 DeepSeek 官方余额、赠金和充值余额
- 从 Claude Code 本地日志去重统计 DeepSeek 今日与本月累计 Token；未变化的日志直接复用聚合缓存
- 按 DeepSeek V4 官方人民币价格估算本机本月累计花费
- DeepSeek API Key 使用 Windows DPAPI 当前用户加密
- 位置、贴边状态、置顶偏好、当前数据源和低余量提醒设置自动保存在本机
- 本地记录脱敏余量样本，在详情中显示 24 小时与 7 天趋势
- 使用历史跨重启和版本更新持久化，并按本地日期、时区和 UTC 偏移校准
- 可导出或导入合并脱敏使用记录，便于备份、换机和恢复
- “数据与诊断”提供 Provider 健康状态及可复制、可导出的脱敏报告
- 根据最近下降速度预测预计耗尽时间；Codex 会同时考虑额度重置时间
- 余量首次降到用户设定的阈值时通过通知区域提醒；默认 20%，可在右键菜单调整或关闭

## 系统要求

- Windows 10 或 Windows 11
- Windows PowerShell 5.1
- Codex 模式：已运行过至少一次 Codex 任务
- DeepSeek 模式：DeepSeek API Key；本地 Token 统计需要运行过 Claude Code + DeepSeek

无需安装第三方模块或运行时。

## 快速开始

1. 从 GitHub Release 下载 `Remaining-Margin-Float-v*.zip`，或克隆源码。
2. 解压 ZIP 并保持目录内容完整，然后运行 `RemainingMarginFloat.exe`；源码用户
   可以双击 `Start-RemainingMarginFloat.cmd`；仓库中已有当前版本构建时，该
   脚本会优先启动打包版，否则回退到源码模式。
3. 点击悬浮窗查看详情，按住左键拖动位置。

也可以从 PowerShell 启动：

```powershell
powershell.exe -NoProfile -STA -File .\src\RemainingMarginFloat.ps1
```

重复执行启动命令不会创建第二个窗口，而是将正在运行的窗口带到前台。

`Start-RemainingMarginFloat.cmd` 是透明的本地启动入口，不隐藏窗口，也不绕过
PowerShell 执行策略。它会优先异步启动 `dist` 中与 `VERSION` 匹配的打包版，
没有打包版时才在当前命令窗口运行源码，并显示明确状态。面向普通用户建议
直接使用 Release ZIP 中的启动器。

## 打包

在项目根目录运行：

```powershell
powershell.exe -NoProfile -File .\Build-Package.ps1
```

脚本会在 `dist` 中生成透明的便携目录和 ZIP。ZIP 内包含启动器、可审查的
PowerShell 脚本、使用说明、MIT 许可证和隐私说明。启动器运行前会验证脚本
SHA-256，并在自身进程中
托管 PowerShell；不会释放内嵌脚本、创建隐藏的 `powershell.exe` 子进程或使用
`ExecutionPolicy Bypass`。

发布文件示例：

```text
Remaining-Margin-Float-v1.6.0.zip
Remaining-Margin-Float-v1.6.0.zip.sha256
```

推送与 `VERSION` 一致的标签（例如 `v1.6.0`）后，`Windows 发布`工作流会
在 Windows Runner 上测试、构建、验证并生成 ZIP，随后创建或更新
GitHub Release。手动运行该工作流时只生成 Actions Artifact，不创建 Release。

当前项目发布未签名的透明便携包，不要求代码签名。安全报告方式见
[SECURITY.md](SECURITY.md)。

## 源码结构

运行入口是 `src\RemainingMarginFloat.ps1`，它按照 `src\Components.psd1`
声明的顺序加载同一脚本作用域中的组件。Provider、基础设施、诊断与 UI 已分别
放在对应目录，主窗口布局位于 `src\UI\MainWindow.xaml`。

为了保持便携发布物简单且可审查，构建时会按照同一组件清单把源码和 XAML
合并为 ZIP 内的单个 `RemainingMarginFloat.ps1`。源码模式与打包模式因此执行
同一组组件，同时发布启动器仍只需要验证一个脚本的 SHA-256。

组件职责、Provider 快照契约和维护约束见
[ARCHITECTURE.md](ARCHITECTURE.md)。

## DeepSeek 配置

1. 在悬浮窗或通知区域右键菜单的“数据源”中选择 DeepSeek。
2. 首次切换会自动打开设置窗口；切换成功后，右键菜单才显示“DeepSeek 设置…”。
3. 输入 DeepSeek API Key。
4. 可选填写“预算基准”；设置后小窗显示当前余额相对该金额的百分比，留空则直接显示金额。

也可以通过 `DEEPSEEK_API_KEY` 环境变量提供密钥；环境变量优先于本地加密配置。DeepSeek 模式不依赖 CC Switch。

## 操作

| 操作 | 结果 |
|---|---|
| 单击悬浮窗 | 展开或收起详情 |
| 详情展开后点击桌面或其他应用 | 自动恢复紧凑悬浮窗 |
| 按住左键拖动 | 移动紧凑悬浮窗 |
| 拖到屏幕左侧或右侧 | 开启“贴边隐藏”时自动吸附并收为竖向能量条 |
| 悬停贴边能量条 | 快速滑出紧凑布局；鼠标移开后自动收回 |
| 按住贴边能量条向屏幕内拖动 | 移动 4px 即取消贴边，不会被普通吸附区重新拉回 |
| 鼠标右键 | 打开刷新、数据源、数据与诊断、贴边隐藏、开机启动、置顶和退出菜单；DeepSeek 为当前数据源时才显示其设置 |
| `Esc` | 收起详情 |
| `Ctrl+R` | 立即刷新 |
| 详情右上角箭头 | 收起详情 |
| 单击通知区域图标 | 唤醒窗口并打开详情 |
| 右键通知区域图标 | 打开详情、切换数据源、设置贴边隐藏或开机启动、置顶或退出；DeepSeek 模式下可配置 DeepSeek |

## 数据与隐私

应用读取以下本地文件：

- `%USERPROFILE%\.codex\sessions\**\*.jsonl`
- `%USERPROFILE%\.codex\auth.json`（仅在用户明确启用 Codex 官方接口后）
- `%USERPROFILE%\.claude\projects\**\*.jsonl`

会话文件用于汇总 Codex Token，并提供最近一次本地可见的周期余量快照。
Codex 官方接口访问默认关闭；用户在右键菜单中明确启用后，认证文件才会在
内存中读取账户标识、访问令牌以及 ID Token 的显示名称和邮箱声明。账户标识
和访问令牌仅用于请求 `https://chatgpt.com/backend-api/wham/usage`，不会写入
日志或界面，刷新令牌不会被应用使用。完整说明见 [PRIVACY.md](PRIVACY.md)。

Codex 详情中的今日 Token、输入、输出和缓存均按本机当天可见会话汇总；不把任意一个并行任务的最后一轮数据当作全局状态。

DeepSeek 模式每 60 秒最多请求一次官方 `https://api.deepseek.com/user/balance`。API Key 优先从 `DEEPSEEK_API_KEY` 读取；通过设置窗口保存时，使用 Windows DPAPI `CurrentUser` 加密后写入 `%LOCALAPPDATA%\RemainingMarginFloat\deepseek.json`。首次运行新命名版本时会从旧的 `%LOCALAPPDATA%\CodexMarginFloat` 复制现有配置。应用不读取 CC Switch 密钥或数据库。

DeepSeek 公开余额接口不提供 Codex 式周期重置数据。未设置预算基准时，小窗直接显示货币余额，不推导虚假的百分比。

DeepSeek 的“本月累计花费”由本机 Claude Code 日志中的缓存命中、缓存未命中和输出 Token 按当前官方人民币价格估算，仅代表本机可见调用，不等同于 DeepSeek 账户账单。账户级精确用量请在 DeepSeek Platform 的 Usage 页面按月导出。

趋势历史保存在
`%LOCALAPPDATA%\RemainingMarginFloat\usage-history.jsonl`，只包含数据源、
采样 UTC、本地日期、时区、百分比或余额、币种和可选的重置时间。应用按约
5 分钟聚合并保留最近 8 个本地日历日，不写入账号名称、邮箱、Token、API Key
或访问令牌。右键菜单“数据与诊断”可导出或导入合并同一脱敏格式；换机导入后
会依据目标电脑时区重新校准日期。

## 常见问题

### 显示“等待数据”

应用默认只读取本地 Codex 会话。若显示“余量未知”，请确认本机至少运行过
一次包含余量信息的 Codex 任务。若希望获得最新官方数据，请在右键菜单中明确
启用“Codex 官方接口（读取登录凭据）”，并确认 Codex 已登录且网络可以访问
ChatGPT。

### DeepSeek 显示“等待配置”

先在“数据源”中切换到 DeepSeek，再通过自动打开的设置窗口填写 API Key；之后右键菜单会持续显示“DeepSeek 设置…”。也可以在启动程序前设置 `DEEPSEEK_API_KEY`。HTTP 401 表示密钥无效，需要重新配置。

### 为什么暂时没有耗尽预测

预测至少需要 3 个样本并覆盖 30 分钟。刚启用时会显示“积累 30 分钟后预测”；
检测到 Codex 额度重置或 DeepSeek 充值后，会从新的下降段重新计算。

### 如何调整或关闭低余量提醒

在悬浮窗或通知区域图标的右键菜单中选择“提醒阈值…”，可设置 1–99 的整数
百分比；菜单会同步显示当前阈值。取消“低余量提醒”即可关闭通知。DeepSeek
只有设置预算基准后才有可比较的百分比；未设置预算时只展示余额趋势，不触发
百分比低余量提醒。阈值与开关都会保存在本机，重启后继续生效。

### DeepSeek 没有显示百分比

这是预期行为。余额本身没有自然的百分比分母；填写预算基准后才会显示百分比和双色进度。

### 双击启动脚本后没有第二个窗口

这是预期行为。项目采用单实例运行，第二次启动会唤醒已有窗口。

### 在任务栏中找不到图标

图标位于 Windows 任务栏右侧的通知区域，不是普通任务栏按钮。若未直接显示，请点击通知区域的 `^` 展开折叠图标。

### 展开窗口靠近屏幕边缘

应用会在当前显示器的工作区域内调整详情位置。收起后，小窗会回到展开前的位置。

### 如何设置开机启动

在悬浮窗或通知区域图标的右键菜单中打开“设置开机启动”，可选择：

- 计划任务（推荐）：当前用户登录后启动，支持延迟补启且不需要管理员权限
- 注册表（兼容）：写入当前用户的 `Run` 项
- 启动文件夹（备用）：创建当前用户的启动快捷方式

应用会确保同一时间只保留一种启动方式。选择“关闭”会移除上述三种注册。

Windows 服务运行在隔离的 Session 0 中，无法向当前用户桌面显示 WPF 悬浮窗，因此菜单会明确显示该方式不适用并保持禁用。

### Windows 阻止脚本执行

面向普通用户请使用 Release ZIP 中的 `RemainingMarginFloat.exe`。源码启动入口
不会绕过本机执行策略；如果组织策略禁止运行本地脚本，请不要降低系统安全
设置，也不要通过关闭安全软件或添加全局白名单绕过限制。

### Windows 显示“未知发布者”或安全软件报风险

当前 Release 未进行代码签名，因此 Windows 可能显示“未知发布者”，安全软件
也可能提示风险。只从本仓库的 GitHub Release 下载并核对 SHA-256；如果文件
哈希不一致，请勿运行，也不要通过关闭安全软件或添加全局白名单绕过提示。

## 许可证

本项目采用 [MIT License](LICENSE) 开源。版权和许可声明请参见仓库根目录的 `LICENSE` 文件。
