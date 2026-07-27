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

应用使用命名互斥锁 `Local\CodexMarginFloat.Singleton` 保证单实例运行。第二次启动通过 `Local\CodexMarginFloat.Activate` 自动重置信号唤醒已有窗口。

## 命令行参数

| 参数 | 类型 | 默认值 | 作用 |
|---|---|---|---|
| `-CheckData` | switch | 关闭 | 输出经过筛选的本地用量 JSON，不创建窗口 |
| `-CheckPlacement` | switch | 关闭 | 输出固定测试场景的屏幕避让结果 |
| `-CheckTransitions` | switch | 关闭 | 运行不可见的窗口状态回归并输出 JSON |
| `-Demo` | switch | 关闭 | 使用固定演示数据，不读取真实用量 |
| `-RenderPreview` | string | 空 | 接受 `compact` 或 `expanded`，渲染 PNG 预览 |
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

窗口宽度和高度作为同一个状态原子切换，避免快速操作后落入 370×100 或 108×500 的部分尺寸。
进度条使用两列星号宽度：鼠尾草绿表示剩余比例，暖米灰表示已使用比例。

## 数据字段

应用从最新可用的 `token_count` 事件构造视图模型。

| 界面字段 | 本地来源 |
|---|---|
| 剩余百分比 | `100 - rate_limits.*.used_percent` |
| 周期标签 | `window_minutes` |
| 重置时间 | `resets_at` |
| 套餐 | `rate_limits.plan_type` |
| 本轮 Token | `info.last_token_usage.total_tokens` |
| 输入 Token | `info.last_token_usage.input_tokens` |
| 输出 Token | `info.last_token_usage.output_tokens` |
| 缓存 Token | `info.last_token_usage.cached_input_tokens` |
| 上下文占比 | 本轮 Token ÷ `model_context_window` |
| 今日 Token | 今日活跃本地会话的最新累计值之和 |
| 账号名称与邮箱 | `auth.json` 中 ID Token 的对应声明 |

`Read-SessionSnapshot` 首先读取文件末尾 512KB。若尾部没有 Token 统计，才从头逐行读取整个文件。快照按文件修改时间和长度缓存在进程内。

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
  "Topmost": true
}
```

`Expanded` 当前固定保存为 `false`，因此应用始终以紧凑状态启动。保存的坐标在窗口句柄创建后根据对应显示器的工作区域校正。

## 数据不可用行为

- 找不到会话快照：显示“等待数据”
- 无法解析账号：显示“账号信息暂不可用”
- 缺少重置时间：显示“暂无”
- 缺少可重置次数：显示“未提供”
- 单个损坏的 JSONL 行：跳过该行并继续寻找有效事件

## 相关文档

- [快速开始](../README.md#快速开始)
- [架构说明](ARCHITECTURE.md)
- [贡献指南](../CONTRIBUTING.md)
