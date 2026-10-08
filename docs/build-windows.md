# Windows 构建与离线打包

## 工具链

| 组件 | 版本/要求 |
| --- | --- |
| Flutter / Dart | 3.47.6 / 3.13.5，版本和归档 SHA-256 见 `tools/toolchain-lock.json` |
| Windows C++ | Visual Studio 2026，C++ 桌面开发组件，Windows SDK 10.0.26100.0 |
| 开发脚本 | PowerShell 7、Python 3.11 或以上 |
| 原生准备 | CMake、7-Zip 命令行工具 |
| OCR | PP-OCRv6_small ONNX、ONNX Runtime CPU 1.21.0、OpenCV 4.11.0、yaml-cpp 0.8.0 |
| 安装包 | Inno Setup 6.7.3 |
| EPUB | 系统 WebView2，插件和阅读资源按仓库锁定 |

运行产品不需要 Python 或开发工具。精确依赖见 `pubspec.lock`、`tools/ocr/dependency-manifest.json`。安装开发工具并打开 Visual Studio Developer PowerShell，使 CMake 可发现。

## 准备环境

在仓库根目录执行，所有实际工具位置按本机环境发现。脚本保持 UTF-8，用参数数组调用。

```powershell
$OutputEncoding = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$projectRoot = (Get-Location).Path
$pythonExe = (Get-Command -Name 'python.exe' -CommandType Application | Select-Object -First 1).Source
$bootstrap = Join-Path $projectRoot 'tools/bootstrap_windows.py'
& $pythonExe @('-X', 'utf8', $bootstrap)
$resolver = Join-Path $projectRoot 'tools/toolchain.py'
$flutterRoot = & $pythonExe @('-X', 'utf8', $resolver)
$flutterExe = Join-Path $flutterRoot 'bin/flutter.bat'
& $flutterExe @('pub', 'get')
```

SDK 默认部署到 `.local/toolchains/flutter`。已有锁定版本 SDK 可通过 `bootstrap_windows.py --sdk-dir <SDK路径>` 使用，路径保存在 `.local/toolchain.json`；临时覆盖使用 `OPENNOTE_FLUTTER_ROOT`。环境变量优先，其次本地配置，再次公开锁定清单的相对默认路径。实际 SDK 必须匹配锁定版本，升级仅在明确请求时使用 `--update-lock`。

准备脚本核对下载 SHA-256，网络失败重试及原因留在忽略目录。不要将 SDK 位置写回共享文档、IDE 示例或公开清单。

```powershell
$cmakeExe = (Get-Command -Name 'cmake.exe' -CommandType Application | Select-Object -First 1).Source
$sevenZipExe = (Get-Command -Name '7z.exe' -CommandType Application | Select-Object -First 1).Source
$ocrBootstrap = Join-Path $projectRoot 'tools/ocr/bootstrap.ps1'
$prepare = Join-Path $projectRoot 'tools/ocr/prepare_package.ps1'
$nativeRoot = Join-Path $projectRoot 'native'
$nativeBuild = Join-Path $nativeRoot 'build'
& $ocrBootstrap -SevenZipExe "$sevenZipExe"
& $cmakeExe @('-S', $nativeRoot, '-B', $nativeBuild, '-G', 'Visual Studio 18 2026', '-A', 'x64', '-DOPENNOTE_OCR_BUILD_CLI=ON')
& $cmakeExe @('--build', $nativeBuild, '--config', 'Release', '--parallel', '1')
& $prepare
```

没有 7-Zip 时停止并手动安装，不自动改系统环境。模型位于 `assets/ocr/models/`、原生依赖位于 `native/third_party/`，均不进入 Git。详见 [OCR 复现](../tools/ocr/README.md)。

## 运行和验证

```powershell
$entry = Join-Path $projectRoot 'tools/dev/flutter_dev.py'
& $pythonExe @('-X', 'utf8', $entry, 'run')
# 按本次影响选择范围，以下以工作台为例。
& $pythonExe @('-X', 'utf8', $entry, 'check', '--scope', 'workspace')
```

开发程序使用独立资料库。验证入口配置原生 DLL 环境；PDF/widget 测试需要 Release 目录的 PDFium，OCR 需要准备好的原生 DLL 与模型。首次准备依赖后不必为每次组件测试重新构建。所需构建、Flutter 测试及 MCP 串行执行，详见 [分级验证](testing.md)与[Flutter 开发](flutter-development.md)。

```powershell
$env:CMAKE_BUILD_PARALLEL_LEVEL = '1'
& $flutterExe @('build', 'windows', '--release', '--no-pub')
```

## 分发

Release 目录为 `build/windows/x64/runner/Release/`，必须完整分发应用、Flutter、PDFium、OCR DLL、OpenCV、产品专用 ORT、模型/YAML/字典及许可。应用本地 VC++ Runtime 应与构建工具链对应。不要只分发 EXE。

分发排除 PDB、通用 `onnxruntime.dll` 和仅供 Flutter tester 使用的 `native_assets.json`。保留 `data/flutter_assets/NativeAssetsManifest.json` 中按 DLL 文件名记录的产品部署清单及其引用的原生 DLL；不能把测试的绝对构建路径清单当作产品运行清单。

Release 链接为 WebView 插件的 CodeView 记录指定 PDB 文件名，保留本地调试符号；WIL 诊断使用保留行号和返回地址的级别，不嵌入头文件路径。OCR 的 OpenCV 内联诊断在编译期只保留源文件名，仍保留异常码、函数和行号。每次发布仍须扫描实际 EXE／DLL，不能只依赖这些配置。

打包器接受 `--vc-runtime <CRT目录>` 与 `--iscc <ISCC.exe路径>`，路径由维护者按本机安装指定。依次执行第三方许可准备工具，再调用 `tools/package_windows.py`。完整包输出在忽略目录 `dist/`，包含安装包、便携包、源码包与 `release-manifest.json`。

```powershell
& $pythonExe @('-X', 'utf8', 'tools/prepare_pdfium_notices.py')
& $pythonExe @('-X', 'utf8', 'tools/prepare_inno_translation.py')
& $pythonExe @('-X', 'utf8', 'tools/prepare_vc_license.py')
# 下列两个变量填写本机实际目录；不要将实际路径提交到仓库。
$crtDirectory = Read-Host 'Visual Studio x64 CRT 目录'
$isccExe = (Get-Command -Name 'ISCC.exe' -CommandType Application | Select-Object -First 1).Source
& $pythonExe @('-X', 'utf8', 'tools/package_windows.py', '--vc-runtime', $crtDirectory, '--iscc', $isccExe)
```

仅更新源码与说明时使用 `--source-only`；它更新源码 ZIP 和源码身份，保留安装包/便携包字节，不能视为重新验证二进制。源码包遵守 Git 忽略规则并排除实际本机配置；二进制素材必须在 `packaging/source-assets.json` 中声明来源并匹配大小与哈希。

## 独立运行与安装验证

`tools/verify_windows_package.py --exe <解压后的EXE> --report-dir <新的报告目录>` 在独立临时资料库检查 PDF、OCR、搜索、复制和恢复。只有显式传入 `--installer` 才执行临时安装、同版重装与卸载；该模式遇到已有正式安装登记时停止。使用独立测试用户或机器，不接管现有资料库。

EPUB／PDF 候选使用 `tools/epub/build_candidate.py`，随后打包必须指定 `--candidate --output-dir <独立目录>`。候选使用独立产品身份、安装位置和资料库，不直接装进正式位置。`tools/epub/verify_candidate.py --book <授权测试EPUB>` 使用隔离目录；公开复现应优先选择 `tools/fixtures/epub/` 的自产样本。

默认正式资料目录为 `%LOCALAPPDATA%\OpenNote`。安装、迁移与恢复前保存一致性备份；具体校验步骤见 [验证方法](validation.md)。私有报告与原书留在本地，发布附件须经过 [隐私检查](privacy.md)。
