# 本机容量和性能诊断

诊断只使用显式的空资料目录，不读取或修改默认用户资料库。样本包含1000个独立原生文字 PDF 页面、5000张约256字卡片、当前脑图500节点／400层级关系／100普通关联，以及5100条会话撤销记录；其余4500节点位于另一脑图。数据通过正式 PDF 引擎和仓储 API 准备。

样本由本项目生成；[fixtures/manifest.json](fixtures/manifest.json)记录字节 hash、真实页数和首、中、尾页实际渲染墨迹。结果及历史报告见[RESULTS.md](RESULTS.md)，首版交付范围见[验证摘要](../../docs/validation.md)。

## 生成样本

在项目根目录执行。PowerShell必须显式 UTF-8，用参数数组调用；从环境发现 Python，从本地配置解析锁定 Flutter SDK；解释器须已安装 fixture 所需库。

```powershell
$OutputEncoding=[Console]::OutputEncoding=[System.Text.UTF8Encoding]::new($false)
$pythonExe=(Get-Command -Name 'python.exe' -CommandType Application | Select-Object -First 1).Source
$arguments=@('-X','utf8','tools/verification/generate_capacity_pdf.py')
& $pythonExe @arguments
```

## 功能容量测试

```powershell
$OutputEncoding=[Console]::OutputEncoding=[System.Text.UTF8Encoding]::new($false)
$flutterRoot=& $pythonExe @('-X','utf8','tools/toolchain.py')
$flutterExe=Join-Path $flutterRoot 'bin/flutter.bat'
$arguments=@('test','--no-pub','--concurrency=1','test/performance/capacity_test.dart','--reporter=expanded')
& $flutterExe @arguments
```

写入`capacity-debug-report.json`。这是Flutter tester debug数据，只用于容量闭环及诊断，不能用它认定Release性能目标通过。与其他Flutter test/build协调，禁止并发造成机器提交内存不足。

## 实际Release诊断

程序提供`--verify-performance`入口。先完成 Windows Release 构建，再指定该产物运行启动器：

```powershell
$OutputEncoding=[Console]::OutputEncoding=[System.Text.UTF8Encoding]::new($false)
$projectRoot=(Get-Location).Path
$pythonExe=(Get-Command -Name 'python.exe' -CommandType Application | Select-Object -First 1).Source
$verifyDataRoot=Join-Path ([System.IO.Path]::GetTempPath()) ('opennote-performance-'+[guid]::NewGuid().ToString('N'))
$verifyOutputRoot=Join-Path $projectRoot ('tools/verification/local-release-'+[DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8))
$arguments=@('-X','utf8','tools/verification/run_performance.py',
  '--exe',(Join-Path $projectRoot 'build/windows/x64/runner/Release/opennote.exe'),
  '--fixtures',$projectRoot,
  '--data-dir',$verifyDataRoot,
  '--output',$verifyOutputRoot,
  '--visible-application')
& $pythonExe @arguments
```

活动资料库使用本机临时目录，报告可留在忽略的源码诊断目录。启动器拒绝非空资料目录或已含报告的输出目录；运行后保留资料库和报告，不自动删除或重用。

参数`--exe`指定 Release 程序，`--fixtures`指定包含样本的项目根，`--data-dir`与`--output`指定独立目录。示例中的`--visible-application`显示实际主窗口；省略时启动器请求隐藏，但 runner 首帧可能显示窗口。记录的 visible／minimized 状态不证明无遮挡或物理屏幕呈现。

输出`release-app-report.json`、`process-memory-samples.jsonl`和`local-performance-report.json`。Windows GetProcessMemoryInfo 提供进程累计工作集／提交峰值，100ms私有内存采样另列。正式组件接收鼠标拖动和滚轮事件，实际位移／缩放断言通过后采集引擎 FrameTiming；忽略准备阶段及首5帧。搜索分别记录首次与后续首100条结果，注明缓存状态。

报告绑定实际二进制 SHA-256，保留逐帧 phase、cache 数量／字节和可见节点范围。各阶段 p95 为独立分位数，不能相加或相减代替同一帧分析；节点可见数变化时，应按实际范围报告混合样本。

## 结论边界

- 本机硬件与最低基准机（4物理核/16GB/SSD）分开，不能外推最低配置已达标。
- 运行器总耗时包含造数据，不等于正式 Workbench 启动耗时；工作台与初始 PDF 预览需要读取相应启动报告。
- 首图耗时含新PDF handle、1000页几何解析、真实900×1200渲染、PNG解码与实际帧绘制。它是Reader路径子项，不能等同完整Reader首可见页≤3s。
- 内存覆盖全部真实文本层、卡片、会话历史、脑图与首图；不包含OCR模型和并行OCR，也不代表大型扫描图片书。
- 帧p95≤33ms、首批搜索≤1s、峰值≤2GiB按报告实际值逐项列出，失败项保留，不把所有目标统一标为通过。

## 硬件采集烟测

可用`run_performance.py --probe-output <新JSON路径>`仅验证 Python 自进程的采集链路；该结果不能作为 OpenNote 的内存结论。报告同时保留 Windows 注册表原始 ProductName 与实际 Build／DisplayVersion；显示驱动列表不证明实际渲染 GPU。

执行命令可复用，结果必须对应当次程序身份和生成报告；旧报告不自动证明当前代码或新产物通过。
