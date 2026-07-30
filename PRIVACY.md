# 隐私说明

Remaining Margin Float 是本地运行的开源桌面工具，不包含广告、用户行为分析、
崩溃遥测或项目自建的远程服务器。

## 默认读取的本地数据

- `%USERPROFILE%\.codex\sessions\**\*.jsonl`：汇总本机可见的 Codex Token，
  并读取会话中最近一次有效的额度快照。
- `%USERPROFILE%\.claude\projects\**\*.jsonl`：仅在 DeepSeek 模式下汇总本机
  Claude Code 会话中的 DeepSeek Token。
- `%LOCALAPPDATA%\RemainingMarginFloat\settings.json`：保存界面位置、数据源和
  用户主动选择的功能开关。
- `%LOCALAPPDATA%\RemainingMarginFloat\usage-history.jsonl`：保存最近 8 个
  本地日历日的脱敏趋势样本，只包含数据源、UTC 采样时间、本地日期、时区与
  UTC 偏移、百分比或余额、币种和可选重置时间。

这些文件的原始内容不会发送给本项目维护者或项目自建服务。

趋势历史不包含账号名称、邮箱、Token、API Key、访问令牌或原始会话内容。
样本按约 5 分钟聚合，仅用于本机的 24 小时/7 天趋势、低余量提醒、快速下降
提醒和耗尽预测。DeepSeek 设置预算后会同时记录百分比与余额样本，两者均为
不含账号信息的归一化数值。
用户主动使用“数据与诊断”时，可以把同一脱敏格式导出或导入合并；应用不会
自动上传历史或诊断报告。脱敏诊断报告不包含原始日志、账户名称、邮箱或凭据。

## Codex 官方接口（默认关闭）

只有用户在右键菜单中明确启用“Codex 官方接口（读取登录凭据）”后，应用才会
读取 `%USERPROFILE%\.codex\auth.json` 中的：

- 访问令牌；
- ChatGPT 账户标识；
- ID Token 中的显示名称和邮箱声明。

访问令牌和账户标识只用于向
`https://chatgpt.com/backend-api/wham/usage` 请求当前账户用量。刷新令牌不会
被应用使用。令牌不会写入应用设置、日志、界面或临时文件。

用户可随时在同一菜单中关闭该功能。关闭后应用停止访问认证文件和官方接口，
并清除内存中的官方用量缓存。

## DeepSeek

只有用户选择 DeepSeek 并提供 API Key 后，应用才会请求
`https://api.deepseek.com/user/balance`。通过设置界面保存的 API Key 使用
Windows DPAPI `CurrentUser` 加密，保存在
`%LOCALAPPDATA%\RemainingMarginFloat\deepseek.json`。也可以使用
`DEEPSEEK_API_KEY` 环境变量，避免落盘。

## 开机启动与本地修改

开机启动默认关闭。只有用户主动选择后，应用才会创建计划任务、当前用户
`Run` 注册表项或启动文件夹快捷方式，并确保同一时间只保留一种。选择“关闭”
会移除这些注册。

## 删除数据

关闭开机启动并退出应用后，删除
`%LOCALAPPDATA%\RemainingMarginFloat` 即可清除本应用保存的设置、缓存和
DeepSeek 加密配置。应用不会删除 Codex 或 Claude Code 自身的数据。

## 第三方版本

Fork、二次打包和第三方构建可能修改上述行为。只有
`https://github.com/LinLey-Nancy/Remaining-margin-float` 的 Release 页面属于
本项目官方发布渠道。
