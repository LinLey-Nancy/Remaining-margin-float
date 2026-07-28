# 火绒误报申诉模板

> 仅在正式 EXE 已完成受信任代码签名、时间戳和本地验证后使用。请替换所有
> `<占位符>`，不要附加真实 Token、API Key、`auth.json` 或会话日志。

## 标题

开源软件 Remaining Margin Float `<版本>` 被识别为“风险软件”

## 正文

您好：

我是在 GitHub 公开维护的 Windows 开源工具 Remaining Margin Float 的开发者。
火绒最新版将官方发布文件识别为“风险软件”并删除，现申请复核。

- 项目主页：
  `https://github.com/LinLey-Nancy/Remaining-margin-float`
- 官方 Release：`<Release URL>`
- 版本：`<版本>`
- 火绒检测名称：`<安全日志中的完整检测名>`
- 火绒版本与病毒库：`<版本信息>`
- ZIP SHA-256：`<ZIP SHA-256>`
- EXE SHA-256：`<EXE SHA-256>`
- Authenticode 发布者：`<发布者>`
- 签名时间戳：`<时间戳>`

该版本的发布结构和安全措施：

1. EXE 不包含或释放 Base64 PowerShell 脚本。
2. 不创建隐藏的 `powershell.exe` 子进程。
3. 不使用 `ExecutionPolicy Bypass` 或 `EncodedCommand`。
4. 发布包中的脚本是可见文件，启动器运行前会校验其 SHA-256。
5. 开机启动默认关闭，仅在用户主动选择后配置。
6. Codex 官方接口访问默认关闭；只有用户明确确认后才读取本机 Codex 登录
   凭据，并仅请求 `https://chatgpt.com/backend-api/wham/usage`。
7. 项目不包含广告、推广、静默安装、项目自建遥测或远程控制功能。

源码、构建脚本、隐私说明和签名政策均已公开。烦请分析该样本并在确认后修正
误报。如需其他不含用户隐私的复现信息，我可以继续提供。

谢谢。

## 建议附件

- 火绒拦截截图；
- 火绒安全日志导出；
- Authenticode 验证截图；
- `PRIVACY.md`；
- 最终签名 EXE 或官方 Release 下载链接。
