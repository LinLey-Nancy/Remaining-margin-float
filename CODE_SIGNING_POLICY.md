# Code signing policy

## 官方项目与发布渠道

本政策适用于
`https://github.com/LinLey-Nancy/Remaining-margin-float` 的官方发布物。
Fork 和第三方构建不属于官方签名范围，必须使用各自的发布者身份。

## 签名服务

本项目计划使用：

> Free code signing provided by SignPath.io, certificate by SignPath Foundation.

该声明在项目获 SignPath Foundation 接纳并完成流水线配置后生效。在此之前，
任何未签名构建都只能作为测试产物，不应作为正式公开 Release。

签名私钥由签名服务的 HSM 管理，不导出为 PFX，也不保存在仓库、开发机或
GitHub Secrets 中。GitHub Secret 中只允许保存可撤销的 SignPath API Token，
该 Token 本身不是代码签名私钥。

## 团队角色

- Committer / reviewer：仓库维护者 `LinLey-Nancy`
- Signing approver：仓库所有者 `LinLey-Nancy`

贡献者提交的变更需要由维护者审核。签名请求需要人工批准，且只能来源于官方
GitHub Actions 工作流。正式发布只能从受保护的版本标签发起；首次签名验证可
从受保护的默认分支手动发起，但该产物不得作为正式 GitHub Release 发布。

## 发布流程

1. 从版本标签干净检出源代码。
2. 运行应用诊断和发布策略检查。
3. 构建透明发布目录。
4. 将未签名 EXE 作为 GitHub Actions 构建产物提交给 SignPath。
5. 人工批准签名请求。
6. 验证 Authenticode 签名状态、预期证书指纹和可信时间戳。
7. 使用已签名 EXE 重新生成 ZIP。
8. 最后生成 ZIP 的 SHA-256 并发布到 GitHub Release。

任何签名后的二进制修改都会破坏签名。校验和不得在签名前生成。
GitHub Actions 中使用的第三方 Action 必须固定到审核过的完整提交哈希。

## 账户安全

仓库维护者、审核者和签名批准者必须为 GitHub 和 SignPath 启用多因素认证。
SignPath API Token 应限制权限并在泄露或人员变更时立即轮换。
