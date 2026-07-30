# Remaining Margin Float v1.4.3

## 发布链维护

- `actions/upload-artifact` 升级到基于 Node.js 24 的 v7.0.1，并固定到官方完整提交哈希，消除 GitHub Actions 的 Node.js 20 淘汰提示。
- CI 与标签发布固定安装 PSScriptAnalyzer 1.25.0，对全部受版本控制的 PowerShell 脚本执行错误级静态检查。
- 静态检查直接按 UTF-8 读取源码，兼容仓库中不同的 BOM 与换行格式，不把历史命名风格警告升级为发布阻塞。

## 干净环境回归

- 新增固定空用户目录性能回归，模拟全新 Windows Runner 没有 Codex 或 Claude Code 日志的情况。
- 空目录下必须返回零文件、零字节，同时继续验证两份 8 MB 合成 Codex 日志的有界尾部读取。
- 该回归会在普通 CI 和标签发布中执行，避免依赖开发机已有日志才能通过。

## 兼容性

- 用户界面、启动方式、配置路径、提醒行为和 60 秒刷新周期保持不变。
- 继续支持 Windows PowerShell 5.1、WPF 和零运行时第三方依赖。
- 发布包仍为未签名的透明便携包。

## 下载

下载 `Remaining-Margin-Float-v1.4.3.zip`，解压后保持目录内容完整，并运行
`RemainingMarginFloat.exe`。可使用同名 `.sha256` 文件核对下载完整性。
