# 项目首页与导航验证

首页支持一级分类、搜索、排序、分页封面及回收站。返回首页先保存草稿、标签、当前文档/脑图和阅读位置；失败时保留工作台。退出与返回并发不得丢失尚未保存的内容。

- 数据安全入口：`test/data/project_home_test.dart`，覆盖迁移快照、恢复、分类导航和事务失败保全。
- 首页与生命周期入口：`test/ui/project_home_test.dart`，覆盖封面、搜索、交互、保存失败及返回/退出竞争。
- 工作台入口：`test/workspace/workbench_test.dart`，覆盖文档/页码恢复、编辑、OCR 及句柄关闭。
- 视觉配置：`test/goldens/baseline-environment.json`；实际 Windows 导航在需要时使用官方 Dart MCP 与独立临时资料库。

按 [分级验证](testing.md)选择实际范围。测试不能使用日常学习资料；结果按 [验证方法](validation.md)记录，不沿用其他构建的验收。
