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

源码模式便于维护，发布构建目录继续保持五个可审查的应用文件：

- `RemainingMarginFloat.exe`
- `RemainingMarginFloat.ps1`
- `README.txt`
- `LICENSE`
- `PRIVACY.md`

`Build-Installer.ps1` 再将这五个文件编译成 Inno Setup 安装程序。正式 Release
只发布 `*-Setup.exe` 与其 SHA-256；安装器提供用户级默认目录、可选安装位置、
开始菜单/桌面快捷方式、覆盖升级和卸载。安装目录写入当前用户注册表后，开机
启动直接指向稳定安装路径；便携目录仍使用原有哈希命名托管副本。

## 组件职责

| 目录 | 职责 |
|---|---|
| `App` | 应用初始化、Provider 刷新协调和后台历史补录生命周期 |
| `Core` | 用量快照契约、Provider 价格目录、趋势历史、加密全量状态仓库、耗尽预测和窗口几何等核心逻辑 |
| `Providers` | Codex、DeepSeek 与 Kimi Code 数据读取、解析和快照生成 |
| `Infrastructure` | 本地配置、DPAPI、开机启动、版本更新、持久化和脱敏运行日志 |
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

Codex 快照还携带 `FiveHour*` 与 `Weekly*` 两组周期字段，包括可用性、已用百分比、
剩余百分比和重置时间，并通过 `PlanType` 与 `PrimaryQuotaPeriod` 明确套餐和主周期。
Plus 的 `RemainingPercent` / `HasProgress` 代表 5 小时窗口；`pro` / `prolite` 代表
每周窗口。贴边能量条、趋势、低额度提醒和快速下降提醒统一消费套餐主指标，且
历史样本按 `FiveHour` / `Weekly` 隔离。

KimiProvider（`Providers\KimiProvider.ps1`）从 Kimi Code CLI 本地配置解析
凭证：优先 `credentials\*.json` 的 OAuth 访问令牌（只读 access token，不刷新），
回退 `config.toml` 中 `[providers.*]` 段的 `api_key` 与 `base_url`，并尊重
`KIMI_CODE_HOME` 环境变量。自动读取不可用时，回退到用户在“Kimi Code
手动配置…”窗口中输入的 API Key：手动 Key 使用 DPAPI `CurrentUser` 加密，
与 KeyHint 后四位一起保存在 `%LOCALAPPDATA%\RemainingMarginFloat\kimi.json`，
并已加入旧目录 `CodexMarginFloat` 的迁移白名单；快照账号行注明凭证来源
（Kimi Code CLI（OAuth 登录）/ Kimi Code CLI（config.toml）/ 手动配置）。
官方配额接口为 GET `{base_url}/usages`（Bearer
认证，默认 `https://api.kimi.com/coding/v1`），返回每周配额（已用百分比与
重置时间）和 300 分钟的 5 小时滚动窗口。快照契约字段与 Codex 对齐：复用
`FiveHour*` / `Weekly*` 两组周期字段，5 小时窗口为主额度，每周为补充；本地
Token 统计解析 `sessions\**\agents\main\wire.jsonl` 的 `usage.record` 记录
（inputOther/output/inputCacheRead/inputCacheCreation），汇总今日 Token、
最近一轮与缓存命中率，并跳过子代理目录。官方接口失败时沿用上次成功快照，
数据过期后按“余量未知”展示，不伪装 0%。

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
- 自动更新只检查公开的 GitHub 最新正式 Release；版本必须是三段语义版本，
  安装器与校验文件必须匹配固定命名及本仓库 HTTPS 下载路径。下载完成后必须
  验证文件大小、SHA-256 和安装器内嵌版本。手动流程只有 Authenticode 有效且
  证书指纹位于代码内置可信列表时才允许应用启动安装器；可信列表为空时只能
  打开文件所在位置。自动流程必须由安装版用户明确启用并接受未签名风险警告，
  只允许在 Windows 报告为可访问互联网、非计费、非漫游且未受流量限制的连接
  上执行。静默参数不得指定安装目录或任务、不得强制结束进程、不得重启 Windows；
  应用重启只能由安装器专用参数与受控 `[Run]` 条目完成。
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
- 自动刷新间隔固定为 60 秒；手动、自动和启动后的首次成功刷新都必须保存完整
  状态。启动时先恢复当前 Provider 的最后有效快照，随后再执行正常刷新；退出
  时补存最后一次有效快照。失败或仅用于展示的回退快照不得写入状态仓库。
- 完整状态保存在 `%LOCALAPPDATA%\RemainingMarginFloat\state-history`，使用
  “时间节点 + 内容寻址对象”结构：节点记录采集/观察时间、Provider、应用版本
  和 SHA-256，正文排除 `SampledAt` 后哈希去重，并用 DPAPI `CurrentUser`
  加密。账户显示名和邮箱可以作为页面状态加密保存，但所有凭据类字段必须在
  序列化前排除。
- 全量状态严格使用滚动 168 小时保留期。每次保存只追加当日 JSONL 节点分片并
  原子替换小型 `current.json`；轻量过期清理每小时最多运行一次，不得在 UI
  刷新或关闭路径重读、重写整个历史。旧 `manifest.json` 在滚动窗口内兼容读取，
  过期后移除。读取最新对象失败时必须向前回退到最近的有效对象。
- `usage-history.jsonl` 通过已编译的有界扫描器读取，在进入 PowerShell/UI 分析前完成
  格式校验、8 日保留窗口和去重，避免逐行 `ConvertFrom-Json` 阻塞主线程。
  磁盘仍保留每个采样；UI 分析对长时间平坦区间使用每小时代表点，并额外保留所有
  值变化前后的边界点，确保重置、快速下降和趋势拐点不丢失。
- 启动时可以从全量状态补录 `usage-history.jsonl` 缺失的归一化余量样本，但只
  能由当前 Windows 用户在本机解密，并且不得把账户显示名、邮箱或其他页面字段
  写入趋势历史。补录按 Provider、指标、单位和 UTC 采样时间去重；
  `state-history\usage-history-backfill.json` v2 只记录完成时间、覆盖样本数和
  SHA-256 覆盖指纹。只有指纹与完成时间之前的趋势历史一致时才能沿用增量游标，
  否则必须重新扫描滚动 168 小时窗口，避免导入、清理或替换历史后漏补样本。
- 历史补录在首次刷新完成后转入隐藏后台进程，不得阻塞首屏显示；若用户在补录期间刷新，完成后自动补执行一次。
- 运行日志使用脱敏 JSONL，记录关键生命周期事件和慢操作；单文件 2 MB、
  4 个备份上限。日志失败必须被隔离，不得影响启动、刷新或关闭。
- v1.9.0 之前的 v1/v2 Codex 百分比历史没有 `QuotaPeriod`，其既定语义为每周
  额度；读取时必须迁移为 `Weekly`。v3 及后续记录缺少或包含非法周期时仍须拒绝，
  防止损坏数据进入趋势；所有趋势、预测和提醒继续按周期隔离。
- Codex、DeepSeek 与 Kimi Code 的瞬时失败统一使用有界指数退避，并尊重服务端
  `Retry-After`；显示上次成功快照时必须标记采样年龄和失败原因，且不得把展示
  用回退快照写入历史或再次触发提醒。
- Windows Forms 返回的显示器工作区是物理像素，进入 WPF 布局前必须按当前窗口
  `DpiScaleX` / `DpiScaleY` 转换为逻辑坐标。贴边状态下需监测显示器、DPI 与
  任务栏工作区变化，并重新锚定到当前工作区。
- Codex 会话读取只扫描有界文件尾和最近的额度候选，不得因尾部缺少
  `token_count` 而回扫整个历史日志；今日 Token 汇总仍覆盖当天全部会话。
- Codex 官方与本地限额都必须按窗口时长识别 300 分钟的 5 小时窗口和
  10080 分钟的每周窗口，不得假定 `primary` / `secondary` 的固定含义。Plus 缺少
  明确的 5 小时字段时展示为 5 小时未知；`pro` / `prolite` 始终选择每周字段。
- DeepSeek 日志先按完整路径、修改时间和文件长度构建清单键；清单未变化时复用
  今日、本月和最近消息的聚合结果，新增、删除或修改日志后才使用逐文件缓存重新
  聚合。日期或月份边界必须进入清单键，避免跨日复用旧统计。
- 低余量提醒阈值限制为 1–99 的整数，默认 20；阈值与提醒开关共同写入
  `settings.json`，读取非法旧值时回退默认值，不得阻止窗口启动。
- 快速下降时间范围限制为 5–1440 分钟；百分比点阈值限制为 0.1–100，金额
  阈值限制为 0.01–1,000,000,000。Codex 与 Kimi Code 固定使用百分比点，
  DeepSeek 可在百分比点与余额金额之间切换，所有规则均原子校验后写入
  `settings.json`。
- Kimi Code 的 CLI 凭证只读使用本地配置（OAuth 访问令牌不刷新），不得写入
  应用设置、日志、趋势历史或完整状态；手动配置的 API Key 只能以 DPAPI
  `CurrentUser` 加密形式保存在 `kimi.json`，同样不得进入日志或历史。官方
  `usages` 接口与 Codex 共用有界退避重试（上限 30 秒，尊重 `Retry-After`），
  官方接口另有 15 秒快缓存。
- 诊断提前结束时使用 `RmfStopLoading` 控制流，不直接依赖点源脚本中的 `exit`。
- XAML 仅在 `src\UI\MainWindow.xaml` 维护，构建时自动嵌入。
- 发布包仍以最终合并脚本的 SHA-256 为信任边界。
- 趋势历史只保存脱敏的归一化余量样本，保留期固定为 8 天。
- DeepSeek 有预算基准时，同一采样时间同时记录百分比和余额；前者用于相对
  趋势，后者用于不受预算变更影响的金额快速下降判断。
- 趋势历史 v3 同时保存 UTC、当前本地日期、时区、偏移和额度周期；读取、导入时
  按当前时区重新校准本地日期，并兼容 DeepSeek 的 v1/v2 JSONL。Codex v1/v2
  无周期百分比样本按既定语义迁移为 `Weekly`；v3 及后续缺失或包含非法周期的
  样本必须拒绝。新记录只与相同 `FiveHour` / `Weekly` 周期比较，避免套餐切换后
  污染趋势或触发快速下降误报。未来时钟偏差样本可以保留在文件中，但不得进入
  当前趋势与预测。
- 使用记录导入必须与现有样本按 Provider、指标、单位和 UTC 时间去重合并；
  导出和运行诊断不得包含账户名称、邮箱、Token、API Key 或原始日志。
- 普通 `push` 与 `pull_request` 通过 Windows 持续集成执行语法解析、源码诊断、
  打包、真实运行策略及安装/卸载检查；标签发布继续由独立发布工作流负责。
- `CheckRefreshPerformance` 使用真实本地 Codex 与 DeepSeek 日志记录冷启动、
  热读取耗时，并用 8 MB 合成日志验证 Codex 会话读取始终限制在文件尾部；
  同时验证 DeepSeek 聚合缓存命中和日志追加后的失效重算。该诊断只在开发和
  CI 主动调用时运行，不改变生产刷新流程，也不保存用户数据。
- CI 与发布工作流固定使用 PSScriptAnalyzer 1.25.0 检查错误级问题，并在独立
  空用户目录中执行刷新性能回归，确保全新环境没有本地日志时仍可完成诊断。
