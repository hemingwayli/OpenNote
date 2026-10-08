import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/data/open_note_repository.dart';
import 'package:opennote/domain/models.dart';
import 'package:opennote/engines/epub/epub_publication.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final path = Platform.environment['OPENNOTE_EPUB_REAL_BOOK'];
  test('真实书籍只读导入、字体混淆与完整恢复', () async {
    final original = File(path!);
    final before = sha256.convert(await original.readAsBytes()).toString();
    final publication = await EpubPublication.open(path);
    expect(publication.sections, isNotEmpty);
    expect(publication.outline, isNotEmpty);
    final root = await Directory.systemTemp.createTemp('opennote-real-epub-');
    final repository = await OpenNoteRepository.open(rootPath: root.path);
    try {
      final project = await repository.createProject('真实书籍隔离验证');
      final document = await repository.importEpub(
        projectId: project.id,
        filePath: path,
        publication: publication,
      );
      final revision = await repository.getRevision(document.activeRevisionId);
      expect(revision.format, DocumentFormat.epub);
      expect(revision.contentHash, before);
      final backup = await repository.backupTo('${root.path}/book.zip');
      await repository.restoreFrom(backup);
      final recovered = await repository.resourcePath(
        (await repository.getRevision(document.activeRevisionId)).resourceId,
      );
      expect(
        sha256.convert(await File(recovered).readAsBytes()).toString(),
        before,
      );
      expect(sha256.convert(await original.readAsBytes()).toString(), before);
    } finally {
      await repository.close();
      await root.delete(recursive: true);
    }
  }, skip: path == null ? '未指定本机真实书籍，标准回归使用自产样本' : false);
}
