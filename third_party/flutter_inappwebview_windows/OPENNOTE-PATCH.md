# OpenNote Windows 生命周期修正

来源为 flutter_inappwebview_windows 0.6.0，原包清单与哈希见 `upstream-manifest.json`，保留上游 LICENSE。顶层 flutter_inappwebview 仍固定 6.1.5。

修正范围限定为环境创建的 Dart 通道 ID、视图关闭的 Future 合同及相关导出，以及 Windows 消息队列的退出顺序。环境通道改用实际创建的 `env.id`；每个环境登记正在创建／显示的视图，关闭完成后移除。原生关闭 Future 在控件卸载和工作台等待之间共用，避免异步重复 dispose 误关已复用纹理 ID 的新视图。等待实际原生回执后才释放环境；失败继续传播。

应用不在卸载后的 WebView 上等待 JS 回调，实际原生关闭会销毁整个书籍文档。此修正未改变渲染、网络、文本、导航或脚本权限。禁止修改用户的 Pub 缓存。升级依赖时须重新验证此协议及真实换书、退出、恢复流程。

生命周期修正 2 还处理 Windows 自然退出：上游创建当前线程 DispatcherQueue，却将其控制器、合成对象和 RoHelper 留给跨编译单元的静态析构。在本机候选 PDF 自检结束后曾触发 CoreMessaging 访问冲突。最后一个管理器销毁时，先释放视图和合成资源，再执行 ShutdownQueueAsync 并泵送消息至结束，最后释放队列和 RoHelper；保留 WM_QUIT 退出码。此顺序依据[微软 CreateDispatcherQueueController 要求](https://learn.microsoft.com/en-us/windows/win32/api/dispatcherqueue/nf-dispatcherqueue-createdispatcherqueuecontroller)。

共 7 个源码文件存在已声明改动，分别由 `patch-manifest.json` 绑定；上游文件身份保留在 `upstream-manifest.json`。自然退出必须以实际程序退出码验收，写出成功报告不足以证明退出成功。

生命周期修正 3 为桥接回执增加弱生命周期标记。上游 JS→Dart 回执捕获原生视图裸指针；等待中的 Dart 回调可能执行关闭和恢复，回执随后才返回。视图销毁前立即使标记失效，成功及错误回执先确认标记，再访问 JS 执行器。优化版保留本地 PDB 并继续启用 REF／ICF；PDB 不进入分发包，不能依靠改变优化掩盖迟到回执问题。
