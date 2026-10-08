# 分级验证

默认根据改动运行相关检查，保留完整测试作为大改和发布时的回归保障。不删测试、不放宽断言，也不靠历史缓存把未验证代码标为通过。

## 日常使用

在项目根目录运行，沿用固定 SDK、原生依赖与串行策略：

```powershell
$pythonExe = (Get-Command -Name 'python.exe' -CommandType Application | Select-Object -First 1).Source
$entry = 'tools/dev/flutter_dev.py'
# 通用轻量检查：一次静态分析 + 7 项组件预览测试
& $pythonExe @('-X', 'utf8', $entry, 'check')
# 首页行为改动：一次分析 + 首页用例，不追加 quick 或全量
& $pythonExe @('-X', 'utf8', $entry, 'check', '--scope', 'home')
# 更小的修复：指定文件，按名称字面子串选择相关用例
& $pythonExe @('-X', 'utf8', $entry, 'check', '--test', 'test/ui/project_home_test.dart', '--plain-name', '封面')
# 只看将执行什么；不会运行或写报告
& $pythonExe @('-X', 'utf8', $entry, 'check', '--scope', 'data', '--dry-run')
```

PowerShell 包装入口 `tools/dev/flutter-dev.ps1` 支持与 Python 相同的检查范围（包括 `epub`），以及 `-TestPath`、`-PlainName`、`-SkipAnalyze`、`-DryRun`。例如，在项目根目录预览 EPUB 检查计划：

```powershell
$wrapper = Join-Path (Get-Location).Path 'tools/dev/flutter-dev.ps1'
& $wrapper -Action check -Scope epub -DryRun
```

VS Code 默认测试任务为“OpenNote: 日常快速检查”；模块任务提供范围选择。

| 范围 | 适用改动 | 执行内容（默认先分析） |
| --- | --- | --- |
| `quick` | 基础控件、局部样式、预览 | 7 项轻量组件测试；不是所有功能的冒烟保障 |
| `home` | 首页、分类交互、封面、返回与退出 | 首页组件与生命周期测试 |
| `map` | 脑图、大纲 | 脑图与大纲组件测试 |
| `reader` / `pdf` | 阅读器 UI / PDF 引擎 | 阅读器组件 / 整个 PDF 测试目录 |
| `epub` | EPUB 解析、来源、迁移和恢复 | `test/epub`；真实 WebView 另走隔离原生验收 |
| `data` | 仓储、数据库、迁移、备份 | 数据层测试，包含迁移与恢复安全边界 |
| `controller` | 工作台状态与命令控制 | 应用控制器测试 |
| `workspace` | 跨组件编辑、保存、快捷键、回源 | 工作台集成测试，按需用名称过滤 |
| `ocr` | OCR 引擎、队列、文字层 | OCR 测试，不在普通 UI 修改时运行 |
| `tools` | Python 开发／归档工具 | Python 工具测试，不运行 Dart 分析 |
| `full` | 跨层核心变更、全局主题／依赖、发布验收 | 分析 + 全部 Flutter（含 Golden／OCR／容量）+ Python 工具测试 |

`--test` 可重复指定，替代 scope 的默认文件列表；`--plain-name` 为字面子串，不是正则。拼错路径或未匹配测试应失败，不算成功。`full` 不接受用例过滤，避免“全量”被意外缩减。同一次变更分析已通过且源码未再修改时，可用 `--skip-analyze` 避免重复。

## 视觉检查和真实程序

- 无布局影响的文档修改：不跑 Flutter。
- 局部视觉变化：优先相关组件／页面预览，需要整页比较时用 `golden`，默认 **1920×1080 单一配置，共 11 张**。
- 特定尺寸问题：`golden --golden-profile 1280x720` 或 `1920x1080-at150`。
- 全部 33 张：`golden --golden-profile all`。`check --scope full` 自带全部 Golden，通过后无需再跑一次 `golden`。
- 更新截图同样支持 `update-goldens --golden-profile <配置>`；查看本次实际变化的图片，登记脚本保留未改变的基线。不要为修复失败而直接覆盖截图。
- 仅编辑器布局变化时，可在本次命令进程设置 `OPENNOTE_EDITOR_GOLDENS_ONLY=1`，再执行 `update-goldens --golden-profile all`；只生成三张 `editor-*`，其他 30 张不截图、不覆盖。取消该变量后，普通 Golden 保持原有全状态检查。
- MCP：导航／原生交互需要真实窗口补充证明时执行一次；普通文案、间距或局部控件修改默认跳过。
- Profile：只针对性能相关改动或实际卡顿；Release：需要交付可运行版本或验证原生构建时执行。二者均不随 `check` 自动运行。

## 原生窗口栏

修改 Windows 自绘窗口栏时，先运行 `check --test test/ui/window_bar_test.dart`，再单独编译 `test/windows`。它直接使用正式 `Win32Window` 源码，检查最大化／还原、最小化恢复、点击取消、模态命中、工作区边界、全屏往返和 DWM 圆角策略；不启动 Flutter 引擎或资料库。需要已有 `windows/flutter/ephemeral` 引擎头文件及 DLL，不会下载依赖。

```powershell
$projectRoot = (Get-Location).Path
$cmakeExe = (Get-Command -Name 'cmake.exe' -CommandType Application | Select-Object -First 1).Source
$source = Join-Path $projectRoot 'test/windows'
$build = Join-Path $projectRoot '.local/verification/window-chrome/native'
& $cmakeExe @('-S', $source, '-B', $build, '-G', 'Visual Studio 18 2026', '-A', 'x64')
& $cmakeExe @('--build', $build, '--config', 'Debug', '--parallel', '1')
$flutterDll = Join-Path $projectRoot 'windows/flutter/ephemeral'
$env:PATH = $flutterDll + [System.IO.Path]::PathSeparator + $env:PATH
$testExe = Join-Path $build 'Debug/window_chrome_test.exe'
& $testExe
```

原生窗口测试与 Flutter 测试／应用构建保持串行。圆角测试需要 Windows 11；DWM 属性通过还需实际窗口截图确认四角裁剪和按钮画面，不表示正式安装版本已更新。

## 结果与耗时

每次 `check` 保存命令、各步退出码、各步耗时、总耗时和范围到 `.local/verification/<时间>/report.json`，Flutter 用例明细同目录 `tests.jsonl`。第一步失败立即停止，修复后只复验受影响范围。

结果只证明本次实际执行的范围。耗时以本次报告为准；发布时再执行与发布目标一致的完整验收。公开摘要须按 [隐私说明](privacy.md)脱敏。
