# Remaining Margin Float 自制主题接口 v1

把本说明、my-theme.json 和 display-contract.json 一起交给 AI，描述想要的外观，要求只生成一份 UTF-8 JSON。应用右键或托盘 → 主题 → 导入主题，选择文件即可使用。主题保存在本机数据目录的 themes 子目录，选择会跨重启保存。

my-theme.json 是可直接导入的完整示例，builtins 是四个内置主题的参考定义。请更改 id（小写字母开头，3–48 个小写字母、数字或连字符）与 name。classic/native/instrument/paper 是保留 id。重复 id 不会覆盖原文件。schemaVersion 当前必须为 1，未知字段会明确拒绝。

layout.base 决定布局：classic 保留原界面；native、instrument、paper 使用顶部数据源工具栏和独立额度区。layout.quotaStyle 可以是 bar（横条）、ring（圆环）、rail（竖条）；heroAlignment 可以是 Left 或 Right，作用于展开态数字。ring 的数字固定居中。紧凑窗保持 80×80，详情宽 400，自动展开收起、显示器边界避让由程序负责。经典骨架仅支持 bar + Left，其他骨架可自由组合布局与配色；自制经典骨架同样支持自定义字号。v1 不支持任意 XAML、脚本、网络资源或自定义数据请求。

colors：所有颜色必须为 #RRGGBB。TextPrimary/Secondary/Muted 是三级文字；Surface/SurfaceSubtle 是主次背景；Border/Divider 是边框与分隔线；Track 是已使用进度底色；SummarySurface/SummaryBorder 是统计带；ButtonSurface/ButtonHover/ButtonBorder 是按钮状态；BadgeSurface/BadgeBorder/BadgeText 是套餐标签；Unknown 是无数据的中性状态。

typography：textFamily/numberFamily 只能填写本机字体名称，缺失字体由 Windows 回退。compactNumberSize 为 20–28，detailsNumberSize 为 32–52；圆环使用适配小窗口的固定字号。shape：windowRadius 为 6–18，cardRadius 为 0–12，progressThickness 为 2–6。

quotaColors 是 2–12 个 {percent,color}，percent 必须严格递增，以 0 开始、100 结束。按数值逐段连续插值。主额度与每周额度独立着色，未知状态使用 Unknown；高对比度下系统颜色优先。经典主题保留原来的连续配色和贴边能量条。

display-contract.json 描述渲染接口与演示值，并非真实账户数据。主题不需要重新计算额度或 Token。main 表示当前实际显示的配额窗口，包括 Plus/Pro 主周期、每周耗尽时的切换；无预算的 DeepSeek 显示金额，此时 progressAvailable=false，不能伪装成 0%。metrics 四组字段按数据源展示今日/本月花费或 Token 与缓存。trends 是应用计算后的摘要，图表采样、断档与周期隔离仍由宿主负责。

不得把密钥、凭据、Cookie、账户邮箱或真实接口响应写入主题。主题文件仅定义表现，宿主绑定已经校验、格式化的数据。请保持未知、离线、长账户名、低额度、空状态可读。

给 AI 的提示：请依据本接口修改 my-theme.json，只返回完整 JSON，不添加未定义字段，不输出代码块。保留字段名和 schemaVersion，修改 id、名称、配色、字体、形状与布局组合；保证文字与背景对比清楚，余量由高到低连续过渡，保留不可用状态。先确保能导入，再按 80×80 紧凑态与 400 宽详情态检查长文本和深浅背景。