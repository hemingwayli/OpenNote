# Flutter 开发与 UI 验证

开发入口沿用锁定 SDK，提供 Debug/Profile、组件预览、DevTools、Golden、VS Code 和官方 Dart/Flutter MCP。先完成 [Windows 环境准备](build-windows.md)。

## 统一入口

在项目根目录使用 PowerShell 7：

```powershell
$projectRoot = (Get-Location).Path
$pythonExe = (Get-Command -Name 'python.exe' -CommandType Application | Select-Object -First 1).Source
$entry = Join-Path $projectRoot 'tools/dev/flutter_dev.py'
& $pythonExe @('-X', 'utf8', $entry, 'run')
```

| Action | 用途 |
| --- | --- |
| `run` / `profile` | 独立开发资料库上的 Windows Debug / Profile |
| `preview` | 官方组件预览，浏览器地址由启动输出提供 |
| `devtools` | 启动 DevTools，选择空闲端口 |
| `analyze` / `doctor` | 静态分析 / 工具链检查 |
| `check` | 按 `--scope` 或 `--test` 选择检查，默认轻量范围 |
| `golden` / `update-goldens` | 比较 / 更新选定视觉配置 |
| `setup-ide` | 显式安装 Flutter/Dart VS Code 扩展 |
| `mcp-check` | 检查已准备的本机 MCP 配置 |

完整命令参数使用 `--help` 查看。PowerShell 包装入口为 `tools/dev/flutter-dev.ps1`，VS Code 任务提供相同范围选择。日常规则见 [分级验证](testing.md)。

实际 SDK 从 `OPENNOTE_FLUTTER_ROOT`、忽略目录 `.local/toolchain.json` 或锁定清单的相对默认路径解析。入口仅为子进程设置 PATH，不修改其他项目环境。`run` / `profile` 分别使用 `%LOCALAPPDATA%\OpenNote-Development\run` / `profile`；不要覆盖日常资料库。

## IDE 与 MCP

`.vscode/tasks.json`、`launch.json` 和扩展推荐可共享。`.vscode/settings.json` 为本机配置，已被忽略；可以参考 `settings.example.json`，把 SDK 解析器输出填写到 `dart.flutterSdkPath`。

MCP 检查需要先在本机配置服务器，填写锁定 SDK 的 Dart 可执行文件、Flutter 根目录和当前仓库位置；实际配置留在本地，不提交到公开仓库。

MCP 是真实程序交互的补充。需要原生或导航检查时，使用 `tools/dev/check_dart_mcp.py --launch --navigation --screenshot --report-dir <新的本地报告目录>`。脚本启动独立临时资料库并只清理自己创建的实例；日志与截图须留在忽略目录。

## 视觉和性能

视觉规则见 [UI 设计](ui-design.md)，行为规则见 [交互合同](ui-behavior-contracts.md)。Golden 默认比较 1920×1080 的 11 张；响应式/DPI 改动补对应配置，整体视觉变化才选择全部 33 张。更新基线只限预期变化，并查看受影响图片与来源清单。

Profile 使用自产 PDF 与明确数量的内存节点，须同时记录实际视口变化、帧阶段、样本数和构建身份。可用 `tools/dev/profile_ui.py` 复现；这不替代最低硬件、持久大库和 OCR 并发验证。

Flutter 测试、构建和 MCP 串行执行，避免 SQLite 原生资产争用。组件预览、静态分析、Golden、实际程序交互和性能检查各自提供不同证据，不能互相替代。结果记录方式见 [验证方法](validation.md)。
