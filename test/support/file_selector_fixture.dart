import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';

/// 只替代系统对话框；返回的文件由真实仓储、PDF 引擎及备份代码处理。
class FixtureFileSelector extends FileSelectorPlatform {
  List<String> importPaths = [];
  String? restorePath;
  String? backupPath;

  @override
  Future<List<XFile>> openFiles({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async => importPaths.map(XFile.new).toList();

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async => restorePath == null ? null : XFile(restorePath!);

  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async => backupPath == null ? null : FileSaveLocation(backupPath!);
}
