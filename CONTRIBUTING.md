# 贡献指南

感谢你改进 Codex Margin Float。提交前请保持免安装、Windows 原生和本地只读这三个产品约束。

## 开发要求

- Windows 10 或 Windows 11
- Windows PowerShell 5.1
- Git
- 可选：本机 Codex 会话数据，用于验证真实用量

## 本地运行

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA `
  -File .\src\CodexMarginFloat.ps1
```

重复启动应唤醒已有窗口，不能创建第二个悬浮窗。

## 运行测试

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Smoke.ps1
```

提交前测试必须输出：

```text
Smoke test passed.
```

## 检查真实数据

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File .\src\CodexMarginFloat.ps1 -CheckData
```

输出只能包含界面需要的筛选字段。不要打印 `auth.json` 原文、access token、refresh token 或完整 JWT。

## 生成视觉预览

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA `
  -File .\src\CodexMarginFloat.ps1 `
  -Demo -RenderPreview compact `
  -PreviewPath .\preview-compact.png

powershell.exe -NoProfile -ExecutionPolicy Bypass -STA `
  -File .\src\CodexMarginFloat.ps1 `
  -Demo -RenderPreview expanded `
  -PreviewPath .\preview-expanded.png
```

请检查两种预览没有裁切、突兀阴影或高对比度警示色。

## 代码约束

- 保持 Windows PowerShell 5.1 兼容，不使用仅 PowerShell 7 提供的语法。
- 修改包含中文的 `.ps1` 文件时保留 UTF-8 BOM。
- 文件读取必须允许 Codex 同时写入，使用 `FileShare.ReadWrite`。
- 紧凑和详情尺寸必须成对切换，不重新引入独立宽高动画。
- 新字段必须来自真实本地快照；缺失字段显示“未提供”。
- 新的可见交互需要键盘入口或自动化名称。
- 不添加网络遥测。

## 提交流程

1. 修改代码和相应文档。
2. 运行 Smoke Test。
3. 重新生成并检查视觉预览。
4. 确认 `git diff` 不包含本地认证数据或设置文件。
5. 使用清晰、聚焦的提交信息。

## 问题报告

请包含：

- Windows 版本
- PowerShell 版本
- 重现步骤
- 预期行为和实际行为
- 截图或错误文本

请勿上传 `%USERPROFILE%\.codex\auth.json` 或未经脱敏的会话日志。
