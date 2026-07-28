# SignPath Foundation 接入清单

仓库已经准备好 SignPath GitHub Actions 接口，但正式签名需要仓库所有者完成
外部申请和账号配置。

## 1. 申请前检查

- 仓库保持公开。
- MIT 许可证覆盖全部项目代码。
- GitHub 账号启用多因素认证。
- 阅读并确认 `PRIVACY.md`、`SECURITY.md` 和
  `CODE_SIGNING_POLICY.md` 与实际行为一致。
- 确认正式发布物不包含真实 Token、API Key、测试账户或私有组件。
- 至少保留一个已有 Release，并在 README 中清楚说明功能和下载方式。

申请入口：

`https://signpath.org/apply`

SignPath Foundation 是否接纳项目由其独立决定，不能保证申请一定通过。

## 2. SignPath 项目配置

获批后：

1. 安装 SignPath GitHub App，并只授权本仓库。
2. 建立 GitHub Trusted Build System。
3. 建立项目和 Artifact Configuration。
4. Artifact Configuration 的输入是 GitHub Actions 自动生成的 ZIP，ZIP 中包含
   `RemainingMarginFloat.exe`；只对该 EXE 执行 Authenticode 签名。
5. 对 Product name、File description、Company name 和版本元数据设置限制。
6. 建立需要人工批准的正式 Signing Policy。
7. 使用 SignPath Foundation 提供的证书，并启用 RFC 3161 时间戳。

不要配置脚本去下载、导出或缓存签名私钥。

## 3. GitHub 仓库配置

在 Repository settings → Secrets and variables → Actions 中添加：

Repository variables：

- `SIGNPATH_ORGANIZATION_ID`
- `SIGNPATH_PROJECT_SLUG`
- `SIGNPATH_SIGNING_POLICY_SLUG`
- `SIGNPATH_CERTIFICATE_THUMBPRINT`

Repository secret：

- `SIGNPATH_API_TOKEN`

API Token 不是代码签名私钥，但仍应限制权限并妥善保管。
证书指纹应从 SignPath 项目中实际分配的发布证书取得，去除空格后填入变量；
流水线会要求签名证书精确匹配该指纹，并要求存在可信时间戳。

建议同时：

- 保护默认分支；
- 要求 Pull Request 审核；
- 限制谁可以创建 `v*` 标签；
- 创建需要人工批准的 GitHub `release` environment；
- 为所有维护者启用 MFA。

## 4. 首次测试

1. 在受保护的默认分支上手动运行 `Windows Release`。
2. 勾选 `Submit this manual build to SignPath`。
3. 在 SignPath 中审核并批准请求。
4. 工作流应下载签名后的 EXE、验证签名、重新生成 ZIP 和 SHA-256。
5. 手动运行不会创建 GitHub Release，只会产生可下载的 Actions Artifact。
6. 下载后运行：

   ```powershell
   Get-AuthenticodeSignature .\RemainingMarginFloat.exe | Format-List *
   ```

7. 确认 `Status` 为 `Valid`，发布者、证书指纹和时间戳均正确。

首次签名测试通过后，才创建与 `VERSION` 一致的正式标签。正式标签构建如果没有
有效签名会直接失败，不会发布未签名 EXE。

## 5. 火绒申诉材料

只提交最终签名构建，材料包括：

- 火绒检测名和病毒库版本；
- 发布 ZIP 与 EXE 的 SHA-256；
- Authenticode 发布者和时间戳截图；
- 官方 GitHub 仓库和 Release 链接；
- `PRIVACY.md`；
- 说明启动器不释放脚本、不创建隐藏 PowerShell 子进程、不使用
  `ExecutionPolicy Bypass`；
- 说明 Codex 官方接口默认关闭，并由用户明确授权。

不要向火绒或任何公共扫描站点提交包含真实用户凭据的文件。
