# 验证方法与适用范围

验证结果须绑定具体源码、二进制、环境、样本和命令。本文提供可复现方法，不将历史开发机结果或截图作为当前安装包的验收证明。当前数据库 schemaVersion 为 11，备份 formatVersion 为 1。

## 按影响范围检查

日常入口与模块选择见 [分级验证](testing.md)。文档修改检查内容、格式、公开链接及隐私边界；开发工具选择 `tools`。UI、PDF、EPUB、OCR、数据层和工作台按实际影响选用相关测试。

全量检查、全部 Golden、MCP、Profile 与安装生命周期各自有适用条件，不作为每次局部改动的默认清单。Flutter 测试与原生构建串行执行。

## 可复现样本

| 场景 | 来源与入口 |
| --- | --- |
| 原生、扫描、混合、旋转、链接 PDF | `tools/fixtures/pdf/` 与 `tools/fixtures/generate_pdf_fixtures.py` |
| EPUB 2／3、重排、固定和混合布局 | `tools/fixtures/epub/` 与 `tools/epub/create_fixtures.py` |
| OCR 印刷样本 | `test/ocr/fixtures/`；[OCR 复现说明](../tools/ocr/README.md) |
| 公共领域扫描单页 | [样本来源](../test/ocr/fixtures/real-books/README.md)，仅限声明的样本 |
| 首页、编辑器与脑图视觉 | `test/goldens/baseline-environment.json` 与 `test/goldens/baselines/` |
| 容量与帧计时 | [性能验证](../tools/verification/README.md) |

样本来源及固定 SHA-256 见 `packaging/source-assets.json`。私人书籍、现有学习资料和个人数据库不属于可公开样本。

## 数据安全和运行验证

迁移、备份恢复、保存/退出并发及资料库切换须检查一致性快照、事务失败保全、隔离校验和恢复后资源完整性。安装测试使用独立用户或机器，不能接管已有正式安装。

Windows 打包、隔离运行及安装/重装/卸载检查见 [构建说明](build-windows.md)。EPUB 原生渲染和生命周期需在系统 WebView2 上验证，widget 替身不能替代原生交互证据。

## 结果记录

测试日志、运行截图、产物清单与回退证据保存在忽略目录 `.local/verification/`。公开摘要只包含脱敏后的命令、范围、结果、产物身份和未覆盖项，不链接本机报告，不包含私人资料指纹或机器身份。

公开发布前还需核对 Git 提交身份、暂存清单、源码 ZIP、选用截图和下载附件。新产物不能沿用旧产物的运行验收结果。最低硬件、干净系统、长时间使用、所有输入法及第三方文档组合均须以相应验证为准。
