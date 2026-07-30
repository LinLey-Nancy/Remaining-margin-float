# 架构说明

Remaining Margin Float 保持 Windows PowerShell 5.1、WPF 和零运行时第三方依赖。
源码按职责拆分，但所有组件仍在同一个脚本作用域中执行，以保持窗口状态、事件
处理和异步刷新行为与原单文件版本一致。

## 两种运行形态

### 源码模式

`src\RemainingMarginFloat.ps1` 是统一入口。它读取 `src\Components.psd1`，
按照清单顺序点源各组件，并从 `src\UI\MainWindow.xaml` 加载窗口布局。

### 发布模式

`Build-Package.ps1` 使用同一个组件清单，将入口头部、XAML 和全部组件合并为
一个带 UTF-8 BOM 的 `RemainingMarginFloat.ps1`。发布启动器验证这个脚本的
SHA-256 后，在当前进程的 STA PowerShell Runspace 中初始化它。初始化管线
结束后，C# 启动器接管 WPF `ShowDialog()` 消息循环，使 Runspace 在等待 UI
事件时保持空闲。UI 的生产事件委托通过统一桥接器，在同一 STA 线程上创建短
PowerShell 管线并串行执行。若事件在另一回调执行期间重入，桥接器会先排入
WPF Dispatcher，待当前回调结束后继续执行。

源码模式便于维护，发布模式则继续保持透明便携包：

- `RemainingMarginFloat.exe`
- `RemainingMarginFloat.ps1`
- `README.txt`
- `LICENSE`
- `PRIVACY.md`

## 组件职责

| 目录 | 职责 |
|---|---|
| `App` | 应用初始化、Provider 刷新协调 |
| `Core` | 用量快照契约、Provider 价格目录、趋势历史、耗尽预测和窗口几何等核心逻辑 |
| `Providers` | Codex 与 DeepSeek 数据读取、解析和快照生成 |
| `Infrastructure` | 本地配置、DPAPI、开机启动和持久化 |
| `UI` | WPF 窗口、状态渲染、交互、托盘与 XAML |
| `Diagnostics` | 数据、窗口、视觉和发布所需的自诊断流程 |

## Provider 契约

Provider 最终向 UI 返回统一快照。`Core\UsageSnapshot.ps1` 在渲染前检查公共
字段，至少包含：

- `ProviderId`
- `Available`
- `HasProgress`
- `RemainingPercent`
- `WindowLabel`
- `Plan`
- `AccountName` / `AccountEmail`
- `SampledAt`
- `Status`
- `Source`

Provider 可以附加自己的余额、Token、缓存和重置字段，但 UI 的公共状态不应
直接依赖 Provider 的网络响应结构。

## 应用状态

跨组件状态仍由统一脚本作用域持有，以兼容 Windows PowerShell 5.1 和发布宿主。
刷新生命周期已经收敛到 `$script:AppContext.Refresh`：忙碌状态、绝对刷新截止
时间、Codex 请求与重试、DeepSeek 请求都由同一个上下文管理。新增刷新状态时
应优先扩展该上下文，不再增加平行的顶层 `$script:` 变量。

Provider 的响应和日志契约使用 `tests\fixtures` 中的固定脱敏样例回归；价格
常量集中在 `Core\ProviderCatalog.ps1`，修改价格时必须同步调整契约断言。

## 维护约束

- 新组件必须登记在 `src\Components.psd1`，顺序即执行顺序。
- 组件不得自行创建新的顶层 Runspace 或改变 STA 模式。
- 打包宿主的 Runspace / 消息循环所有权注入和 UI 事件桥不得删除；生产 UI
  的事件与 Dispatcher Action 都必须通过 `New-RmfEventHandler` /
  `New-RmfAction` 注册。发布测试会实际触发窗口失焦与回调重入，防止
  `ScriptBlockDelegateInvokedFromWrongThread` 和嵌套调用状态异常回归。
- UI 事件桥必须在 Runspace 关闭前停止接收回调，并在单个回调失败时隔离异常，
  不得把 PowerShell Runspace 异常传播成 WPF Dispatcher 的未处理异常。
- 官方余量请求期间，1 秒刷新计时器仍须更新等待时间；发布测试必须实际观察
  到计时器推进后才能通过。
- 自动刷新使用绝对的 `NextRefreshAt` 截止时间计算剩余秒数，不依赖 Tick 次数
  递减；任一刷新完成回调异常都必须解除忙碌态并重新安排下一次刷新。
- Codex 会话读取只扫描有界文件尾和最近的额度候选，不得因尾部缺少
  `token_count` 而回扫整个历史日志；今日 Token 汇总仍覆盖当天全部会话。
- DeepSeek 日志先按完整路径、修改时间和文件长度构建清单键；清单未变化时复用
  今日、本月和最近消息的聚合结果，新增、删除或修改日志后才使用逐文件缓存重新
  聚合。日期或月份边界必须进入清单键，避免跨日复用旧统计。
- 低余量提醒阈值限制为 1–99 的整数，默认 20；阈值与提醒开关共同写入
  `settings.json`，读取非法旧值时回退默认值，不得阻止窗口启动。
- 快速下降时间范围限制为 5–1440 分钟；百分比点阈值限制为 0.1–100，金额
  阈值限制为 0.01–1,000,000,000。Codex 固定使用百分比点，DeepSeek 可在
  百分比点与余额金额之间切换，所有规则均原子校验后写入 `settings.json`。
- 诊断提前结束时使用 `RmfStopLoading` 控制流，不直接依赖点源脚本中的 `exit`。
- XAML 仅在 `src\UI\MainWindow.xaml` 维护，构建时自动嵌入。
- 发布包仍以最终合并脚本的 SHA-256 为信任边界。
- 趋势历史只保存脱敏的归一化余量样本，保留期固定为 8 天。
- DeepSeek 有预算基准时，同一采样时间同时记录百分比和余额；前者用于相对
  趋势，后者用于不受预算变更影响的金额快速下降判断。
- 趋势历史 v2 同时保存 UTC、当前本地日期、时区和偏移；读取、导入时按当前
  时区重新校准本地日期，并兼容 v1 JSONL。未来时钟偏差样本可以保留在文件中，
  但不得进入当前趋势与预测。
- 使用记录导入必须与现有样本按 Provider、指标、单位和 UTC 时间去重合并；
  导出和运行诊断不得包含账户名称、邮箱、Token、API Key 或原始日志。
- 普通 `push` 与 `pull_request` 通过 Windows 持续集成执行语法解析、源码诊断、
  打包和真实运行策略检查；标签发布继续由独立发布工作流负责。
- `CheckRefreshPerformance` 使用真实本地 Codex 与 DeepSeek 日志记录冷启动、
  热读取耗时，并用 8 MB 合成日志验证 Codex 会话读取始终限制在文件尾部；
  同时验证 DeepSeek 聚合缓存命中和日志追加后的失效重算。该诊断只在开发和
  CI 主动调用时运行，不改变生产刷新流程，也不保存用户数据。
- CI 与发布工作流固定使用 PSScriptAnalyzer 1.25.0 检查错误级问题，并在独立
  空用户目录中执行刷新性能回归，确保全新环境没有本地日志时仍可完成诊断。
