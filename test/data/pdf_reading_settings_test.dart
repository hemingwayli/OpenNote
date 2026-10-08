import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/application/workspace_controller.dart';
import 'package:opennote/data/open_note_repository.dart';
import 'package:opennote/domain/models.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late OpenNoteRepository repository;
  late StudyProject project;
  late ManagedDocument first;
  late ManagedDocument second;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('opennote-pdf-sidebar-');
    repository = await OpenNoteRepository.open(
      rootPath: p.join(temp.path, 'library'),
    );
    project = await repository.createProject('独立目录设置');
    final fixture = File('tools/fixtures/pdf/native.pdf').absolute;
    Future<ManagedDocument> import(String title) async {
      final copy = await fixture.copy(p.join(temp.path, '$title.pdf'));
      return repository.importPdf(
        projectId: project.id,
        filePath: copy.path,
        pageCount: 2,
      );
    }

    first = await import('甲文档');
    second = await import('乙文档');
  });

  tearDown(() async {
    await repository.close();
    await temp.delete(recursive: true);
  });

  Future<void> save(ManagedDocument document, bool visible, double width) =>
      repository.savePdfReadingSettings(
        document.activeRevisionId,
        PdfReadingSettings(sidebarVisible: visible, sidebarWidth: width),
        sessionId: repository.sessionId,
      );

  Future<void> expectSettings(
    ManagedDocument document,
    bool visible,
    double width,
  ) async {
    final value = await repository.loadPdfReadingSettings(
      document.activeRevisionId,
    );
    expect(value.sidebarVisible, visible);
    expect(value.sidebarWidth, width);
  }

  test('PDF 目录记忆：按文档独立保存，重启保留状态且不覆盖阅读位置与重做', () async {
    await expectSettings(first, false, 220);
    await expectSettings(second, false, 220);
    await repository.renameProject(project.id, '可撤销的名称');
    await repository.undo();
    final history = repository.undoEntryCount;
    expect(repository.canRedo, isTrue);
    await save(first, true, 310);
    await Future.wait([
      repository.saveReadingPosition(first.activeRevisionId, 1, .35),
      save(first, true, 330),
    ]);
    await repository.saveReadingPosition(first.activeRevisionId, 1, .45);
    await save(second, false, 180);
    await expectSettings(first, true, 330);
    await expectSettings(second, false, 180);
    final position = await repository.loadReadingPosition(
      first.activeRevisionId,
    );
    expect(position!.pageIndex, 1);
    expect(position.offset, .45);
    expect(repository.undoEntryCount, history);
    expect(repository.canRedo, isTrue);
    final root = repository.rootPath;
    await repository.close();
    repository = await OpenNoteRepository.open(rootPath: root);
    await expectSettings(first, true, 330);
    await expectSettings(second, false, 180);
    expect(
      (await repository.loadReadingPosition(first.activeRevisionId))!.offset,
      .45,
    );
  });

  test('PDF 目录记忆：备份恢复保留设置与位置，拒绝旧会话写入', () async {
    await save(first, true, 300);
    await repository.saveReadingPosition(first.activeRevisionId, 1, .2);
    await save(second, false, 260);
    final backup = await repository.backupTo(
      p.join(temp.path, '目录备份.onbackup'),
    );
    final oldSession = repository.sessionId;
    await save(first, false, 150);
    await save(second, true, 420);
    await repository.restoreFrom(backup);
    await expectSettings(first, true, 300);
    await expectSettings(second, false, 260);
    expect(
      (await repository.loadReadingPosition(first.activeRevisionId))!.pageIndex,
      1,
    );
    await expectLater(
      repository.savePdfReadingSettings(
        first.activeRevisionId,
        const PdfReadingSettings(sidebarVisible: false, sidebarWidth: 120),
        sessionId: oldSession,
      ),
      throwsA(
        isA<RepositoryException>().having(
          (error) => error.code,
          'code',
          RepositoryError.staleSession,
        ),
      ),
    );
    await expectSettings(first, true, 300);
  });

  test('PDF 目录记忆：过期回调不修改其他文档，切换时等待已提交设置', () async {
    final controller = WorkspaceController(repository);
    try {
      await controller.initialize(projectId: project.id);
      await controller.openDocument(first);
      final session = repository.sessionId;
      final saving = controller.updatePdfReadingSettings(
        first.activeRevisionId,
        const PdfReadingSettings(sidebarVisible: true, sidebarWidth: 305),
        sessionId: session,
      );
      await controller.openDocument(second);
      await saving;
      expect(controller.pdfReadingSettings.sidebarVisible, isFalse);
      expect(controller.pdfReadingSettings.sidebarWidth, 220);
      await controller.updatePdfReadingSettings(
        first.activeRevisionId,
        const PdfReadingSettings(sidebarVisible: false, sidebarWidth: 120),
        sessionId: session,
      );
      await expectSettings(first, true, 305);
      await expectSettings(second, false, 220);
      await controller.updatePdfReadingSettings(
        second.activeRevisionId,
        const PdfReadingSettings(sidebarVisible: false, sidebarWidth: 175),
        sessionId: session,
      );
      await controller.openDocument(first);
      expect(controller.pdfReadingSettings.sidebarVisible, isTrue);
      expect(controller.pdfReadingSettings.sidebarWidth, 305);
      await expectSettings(second, false, 175);
    } finally {
      controller.dispose();
    }
  });

  test('PDF 目录记忆：非法宽度写入原子失败，旧记录仍使用默认设置', () async {
    await repository.saveReadingPosition(first.activeRevisionId, 1, .3);
    await expectSettings(first, false, 220);
    await save(first, true, 280);
    for (final width in [119.0, 441.0, double.nan, double.infinity]) {
      await expectLater(
        save(first, false, width),
        throwsA(isA<RepositoryException>()),
      );
    }
    await expectSettings(first, true, 280);
    expect(
      (await repository.loadReadingPosition(first.activeRevisionId))!.offset,
      .3,
    );
    await expectSettings(second, false, 220);
  });
}
