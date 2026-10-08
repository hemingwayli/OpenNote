# GitHub 发布

普通用户下载现成 Windows 安装包或便携包。维护者完成编译、分发和核验后上传 Release，源码压缩包供开发者使用，不要求普通用户自行构建。

## 发布范围

按本文流程和仓库中的工具执行发布，完成审查后再推送。

仅要求源码推送或 PR 时审查对应源码范围；要求发布版本时，同时准备安装包、便携包、源码包和分发清单。准备文档不等于授权上传 GitHub；实际发布目标以用户请求和已配置的真实仓库为准。

## 每次发布前的审查

1. 确认 Git 根目录、当前分支、真实 remote、拟公开的文件／提交和版本。没有提交基线时审查全部拟纳入文件；不得把忽略规则当作已跟踪文件或 Git 历史的保护措施。
2. 审查代码与文档：行为描述和版本一致，运行与构建步骤可复现，链接可用，README 提供普通用户安装入口，CHANGELOG 与版本边界清楚，LICENSE／NOTICE／第三方许可及素材来源完整。检查硬编码的私人环境、账号、服务地址和调试数据。
3. 审查隐私：本机路径、用户名、凭据、私人书籍与截图、数据库、备份、日志、MCP／IDE 配置、提交姓名／邮箱及历史中已删除的敏感文件。检查二进制内嵌路径、文档元数据和压缩包内部内容，新增截图须实际查看。
4. 按 [分级验证](testing.md) 执行必要检查。正式二进制 Release 按发布验收处理；同一源码已有可核对的本轮完整证据时复用证据，不重复未受后续改动影响的检查。
5. 运行自动检查并处理阻断项。自动扫描通过后仍须完成语义与素材审查；不能把模式扫描当成绝对无隐私保证。

在项目根目录运行：

```powershell
$pythonExe = (Get-Command -Name 'python.exe' -CommandType Application | Select-Object -First 1).Source
$audit = Join-Path (Get-Location).Path 'tools/release/audit_open_source.py'
# 工作区预检，包括当前 HEAD 可达历史。
& $pythonExe @('-X', 'utf8', $audit, '--selection', 'worktree')
# 暂存完成后，检查真实 Git 索引中的内容。
& $pythonExe @('-X', 'utf8', $audit, '--selection', 'index')
# 最终提交与分发附件检查；报告位于被忽略的 .local/verification/。
& $pythonExe @('-X', 'utf8', $audit, '--selection', 'commit', '--ref', 'HEAD', '--with-release')
```

自动检查输出位置、规则与文件指纹，不输出匹配的秘密值。可在忽略文件 `.local/release-privacy.json` 的 `denyStrings` 数组中补充私人资料标记；不要将这些真实标记放进公开脚本或文档。确认为公开上游信息或自产测试数据的误报可在本地报告中记录理由并按指纹复核；不得跳过真正的凭据／隐私阻断项。

保留与本次文件／提交及 Release 附件 SHA-256 绑定的审查证据。审查后内容发生变化时，重新检查受影响范围；扫描待暂存文件不能代替检查实际索引或最终提交。

## 现成 Release 包

- 使用 [Windows 构建和打包](build-windows.md) 生成同一版本的安装包、便携包和源码包。版本以 `pubspec.yaml`、打包配置及实际应用身份核对；当前打包工具仍有固定版本字段，升级时必须同步修正。
- 保留对应提交、构建命令／结果、产物大小和 SHA-256。二进制必须能追溯到本次源码，已有包缺少来源证据时不能冒充重新构建。
- 验证便携包和安装包实际输入／展开内容、OCR／PDF／EPUB 依赖、模型与许可完整。安装测试使用独立资料库／测试环境，遵守已有正式安装保护，不覆盖用户资料。
- PDB 和 Flutter 测试清单不得分发。仅删除 PDB 文件不足以脱敏：PE 的 CodeView 记录仍可能包含 PDB 的本机绝对路径，须在链接／分发准备阶段处理并重新检查 EXE／DLL。
- `--source-only` 只刷新源码附件，不能用于证明旧安装包与当前源码一致。
- Release 附件包含 `OpenNote-<版本>-Windows-x64-Setup.exe`、`OpenNote-<版本>-Windows-x64.zip`、`OpenNote-<版本>-Source.zip` 和公开分发清单／SHA-256；私有报告不上传。

## 推送与发布完成判定

实际索引、最终提交和附件全部审查后，在当前分支提交并推送，不自动换分支或强制推送。Release tag 指向已核验提交，避免 GitHub CLI 默认从其他分支创建 tag。先核验拟上传清单，再创建／更新 Release；不静默替换已有同名公开附件。

发布后读取 remote 提交、tag 目标、Release 状态与附件清单，完整下载用户安装包和便携包，比较大小及 SHA-256，再更新 README 的真实下载链接。未完成上传／下载核验时明确报告实际边界，不声称发布成功。

参考：[GitHub Releases](https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases)、[GitHub 仓库最佳实践](https://docs.github.com/en/repositories/creating-and-managing-repositories/best-practices-for-repositories)。
