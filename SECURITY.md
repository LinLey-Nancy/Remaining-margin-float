# 安全政策

## 支持范围

安全修复面向最新 GitHub Release。旧版本可能不再单独维护。

## 报告漏洞

请优先使用 GitHub 仓库的 Private vulnerability reporting / Security
Advisory 私下报告安全问题。不要在公开 Issue 中粘贴访问令牌、API Key、
`auth.json`、会话日志、邮箱地址或其他个人信息。

报告中可包含：

- 受影响版本和操作系统版本；
- 最小复现步骤；
- 预期影响；
- 已脱敏的日志或截图；
- 文件 SHA-256。

## 官方发布物

官方发布物只来自：

`https://github.com/LinLey-Nancy/Remaining-margin-float/releases`

每个正式版本应提供：

- 发布 ZIP 的 SHA-256；
- 与版本标签一致的源代码；
- 自动诊断和发布策略检查结果。

当前发布物不进行 Authenticode 代码签名，Windows 会显示“未知发布者”。
请只从上述官方 Release 页面下载，并使用同名 `.sha256` 文件核对完整性。
SHA-256 只能帮助确认下载文件与官方发布资产一致，不能替代源代码审查或
安全软件检测。

## 凭据处理原则

- Codex 官方接口访问默认关闭并需要用户明确确认。
- 不记录或显示 Codex 访问令牌、ChatGPT 账户标识和 DeepSeek API Key。
- 不把凭据发送到项目维护者控制的服务器。
- DeepSeek 本地密钥使用 Windows DPAPI `CurrentUser` 加密。
- 安全测试和误报提交不得包含真实用户凭据。
