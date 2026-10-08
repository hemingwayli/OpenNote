# Windows 离线 OCR 开发说明

产品识别链为：PP-OCRv6_small 官方 ONNX 检测与识别模型 → ONNX Runtime CPU 1.21.0 → OpenCV 4.11.0 前后处理 → C ABI → Dart 工作 isolate。Python/Pillow 仅用于开发验证与打包，不属于产品运行依赖。

## 固定依赖与准备

固定版本为 PP-OCRv6_small、ONNX Runtime CPU 1.21.0、OpenCV 4.11.0 与 yaml-cpp 0.8.0。归档来源、大小、SHA-256 和许可见 [dependency-manifest.json](dependency-manifest.json)。`bootstrap.ps1` 验证固定清单；网络可恢复错误最多重试三次，失败原因保存在忽略的 `download-errors.jsonl`。

开发准备需要 PowerShell 7 与现有 7-Zip。`bootstrap.ps1` 默认使用 `C:\Program Files\7-Zip\7z.exe`，可用 `-SevenZipExe` 指定位置；缺失时停止，不自动安装。

模型位于 `assets/ocr/models/PP-OCRv6_small/`，原生依赖位于 `native/third_party/`，两者不进入 Git。准备、CMake 构建和 `prepare_package.ps1` 命令见 [Windows 构建与离线打包](../../docs/build-windows.md)。安装包包含全部模型，产品运行不需要下载或开发工具。

项目直接解析模型配套 YAML 的字符字典、图像颜色和阈值。`prepare_package.ps1` 使用 CLI 从同一 YAML 导出 `characters.txt`，并准备模型清单、许可与独立验证 payload；运行时权威字典仍是 YAML。模型输出类别数必须与配套字典匹配，否则识别失败。

`NativeOcrService.create()` 在后台 isolate 流式核验五个固定模型/配置/字典文件的大小与 SHA-256，同时核验 manifest 的文件集合和处理版本。预期哈希编入 Dart，替换模型并自改 manifest 的哈希也会被拒绝。当前处理版本为 `opennote-ppocrv6-small-cpu-v2`，更新处理规则须递增版本，避免资料库复用旧顺序的 OCR 层。

## Flutter 和安装包集成

Windows 顶层 CMake `add_subdirectory("../native" ...)` 后，安装 `${OPENNOTE_OCR_BUNDLED_LIBRARIES}` 至应用可执行文件目录，`${OPENNOTE_OCR_MODEL_DIRECTORY}/` 的内容至 `data/ocr/`。原生依赖 DLL 是 `opennote_ocr.dll`、`opennote_onnxruntime.dll` 和对应配置的 OpenCV world DLL（Release 为 `opencv_world4110.dll`）。yaml-cpp 静态编入。

ONNX Runtime 使用产品专用文件名。C++ 从当前 OCR DLL 所在目录用 `LoadLibraryExW` 显式加载、取得 `OrtGetApiBase` 并核对版本 1.21.0，避免宿主同名 DLL 的版本冲突。

独立验证 payload 位于 `native/runtime-ppocrv6-small/`，文件哈希见 [runtime-manifest.json](runtime-manifest.json)。此清单只覆盖该 payload；应用分发按实际 DLL 与安装包字节生成自己的清单。

许可文件及 OpenCV/ORT 第三方通知位于 `assets/ocr/licenses/`，`prepare_package.ps1` 将它们与模型 YAML、派生字典、[模型清单](../../assets/ocr/manifest.json)一起放入 `data/ocr/`。Windows 离线安装包提供应用本地 VC++ Runtime，分发组成与打包步骤见 [构建说明](../../docs/build-windows.md)。

## 接口和坐标

页队列先提取 PDF 原生文字。有有效文字与字符框时保留精确文字层；原生为空的扫描页才加载 OCR 模型并渲染识别。原生与扫描混合书页走同一持久任务提交路径。

`NativeOcrService.create()` 默认从可执行文件目录加载 DLL 和 `data/ocr/`。`recognize(bytes,width:,height:,stride:)` 接受 RGBA8888，PDFium 的 BGRA 必须显式指定 `pixelFormat: OcrPixelFormat.bgra`，转换在推理工作 isolate 内完成。每个服务一次运行一页；`cancel()` 可从主 isolate 调用，`dispose()` 等待当前推理退出后销毁 native handle。

原生结果为输入图像左上原点像素，包含行四边形、文本、置信度、基本阅读顺序与 CTC 近似字符四边形。检测框中至少三条明显长竖列、竖列票数至少为横行的两倍且占框面积65%以上时，以 `basicVerticalColumns` 按右到左、列内上到下输出；完全在长正文列上方的页眉先输出。其余使用 `basicRows`。`writingDirection`、投票与面积占比保存到文字层参数。**字符精度是 `approximateCtcAlignment`，不是模型原生的准确字符框；方向判定和基本行列排序不是多栏/复杂版面还原。**

应用队列以 PDF 实际可见方向渲染（300dpi，上限长边3600像素），使用同一页面的 `PdfCoordinateAdapter` 对四边形逐点逆变换，保存原始 PDF 用户空间。页旋转、裁切偏移、MediaBox 和 UserUnit 存入处理参数；字符范围使用 UTF-16，补充平面字符不能当作一个 UTF-16 单元。

`OcrQueueController` 支持当前页优先、逐页进度、取消和启动恢复；整本入队读取轻量的已完成页索引，避免加载全部文字几何。`enqueuePage()` 显式重识别已完成页时生成新文字层版本，旧卡片锚点、摘录快照和用户内容不被改写。切换/恢复资料库前必须 `await pauseAndDrain()`，恢复后 `await resume()`；任务保存、claim/fail 绑定启动时的资料库 session 与任务身份。

## 验证工具与质量边界

以下均为开发工具，运行结果及证据统一见 [验证记录](../../docs/validation.md)。

| 工具 | 用途与主要参数 |
| --- | --- |
| `test.ps1` | 以 `--concurrency=1` 运行 `test/ocr`，添加 `native/build/Release` DLL 搜索目录；可指定 `-ProjectRoot`、`-FlutterRoot` |
| `validate_native.py` | 生成受控打印页、倾斜页、旋转扫描 PDF，调用真实 C ABI；需要 Pillow 与本机微软雅黑字体 |
| `fetch_public_scan.py URL OUTPUT` | 按来源记录下载单页公共领域扫描，单次最大 8MiB，保留失败原因 |
| `validate_real_books.py --run --prepare-fixtures` | 顺序调用 C++ CLI，评估人工抽段并准备少量真实扫描 fixture |
| `tools/verify_scan_book.py --exe … --pdf … --report-dir …`（项目根目录） | 使用独立资料库检查实际应用的中断续跑、搜索、摘录、锚点及备份恢复 |
| `check_local_scan_excerpt.py --data-dir … --manual … --report …` | 只读验证库，按人工选区计算 CER 并核验少量近似字框位置 |

受控 fixture 覆盖 PDF 渲染、四种旋转、裁切与 UserUnit、OCR 入库、搜索、摘录和队列恢复。真实扫描来源与哈希见 [real-book-samples.json](real-book-samples.json)，人工抽段指标见 [real-book-validation.json](real-book-validation.json)。CER 使用 Unicode codepoint Levenshtein 编辑距离，NFC 并去空白；含标点与去标点分别统计，不转换繁简。

清晰的现代中英单栏与竖排主文适合首版基本流程。旧字体、双行注释、复杂多栏、古式横排右到左和背面透字仍有质量限制；字符框为 CTC 近似对齐，基本行列排序不等于复杂版面还原。搜索 OCR 自身片段仅证明检索流程，识别正确性须与人工基准比较。抽样结果不代表整书、最低硬件或干净系统验收。

用户书诊断使用专用空资料库，续跑须匹配源 PDF SHA 与处理版本；最多抽样八页。原书、渲染图像及人工标注留在本机 `.local` 或临时目录，不进入源码或安装包；诊断报告不输出正文。
