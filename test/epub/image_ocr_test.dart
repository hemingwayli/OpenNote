import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/application/ocr_queue.dart';
import 'package:opennote/data/open_note_repository.dart';
import 'package:opennote/domain/models.dart';
import 'package:opennote/engines/ocr/ocr_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temporary;
  late OpenNoteRepository repo;
  late OcrQueueController queue;
  late ManagedDocument document;
  late StudyProject project;
  const locator = EpubLocator(
    href: 'OPS/ch1.xhtml',
    cfi: 'epubcfi(/6/2!/4/14)',
    imageHref: 'OPS/image.png',
  );
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('epub-image-ocr-');
    repo = await OpenNoteRepository.open(rootPath: temporary.path);
    project = await repo.createProject('按需图片 OCR');
    document = await repo.importEpub(
      projectId: project.id,
      filePath: 'tools/fixtures/epub/epub3-reflow.epub',
    );
    queue = OcrQueueController(
      repo,
      serviceFactory: () => NativeOcrService.create(
        libraryPath: File('native/build/Release/opennote_ocr.dll')
            .absolute
            .path,
        modelDirectory: Directory('assets/ocr/models/PP-OCRv6_small')
            .absolute
            .path,
      ),
    );
  });
  tearDown(() async {
    await queue.disposeAsync();
    await repo.close();
    await temporary.delete(recursive: true);
  });
  test(
    '真实离线图片识别保存原图、来源并可完整恢复，不覆盖正文',
    () async {
      final image = await File('test/ocr/fixtures/bilingual.png').readAsBytes();
      final result = await queue.enqueueEpubImage(
        revisionId: document.activeRevisionId,
        locator: locator,
        image: image,
      );
      expect(result.text, contains('知识整理'));
      expect(
        await repo.indexedEpubSections(document.activeRevisionId),
        isEmpty,
      );
      expect(await repo.loadTextLayers(document.activeRevisionId), isEmpty);
      final hit = (await repo.search(project.id, '知识整理')).single;
      expect(hit.epubLocator!.imageHref, 'OPS/image.png');
      expect(hit.pageIndex, isNull);
      final backup = await repo.backupTo('${temporary.path}/image.opennote');
      await queue.pauseAndDrain();
      await repo.restoreFrom(backup);
      expect(
        (await repo.search(project.id, '知识整理')).single.epubLocator!.toJson(),
        locator.toJson(),
      );
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 1)),
  );
  test(
    '取消初始化中的图片识别不提交迟到结果，可重新按需识别',
    () async {
      await queue.disposeAsync();
      final entered = Completer<void>(), release = Completer<void>();
      queue = OcrQueueController(
        repo,
        serviceFactory: () async {
          entered.complete();
          await release.future;
          return NativeOcrService.create(
            libraryPath: File('native/build/Release/opennote_ocr.dll')
                .absolute
                .path,
            modelDirectory: Directory('assets/ocr/models/PP-OCRv6_small')
                .absolute
                .path,
          );
        },
      );
      final image = await File('test/ocr/fixtures/bilingual.png').readAsBytes();
      final operation = queue.enqueueEpubImage(
        revisionId: document.activeRevisionId,
        locator: locator,
        image: image,
      );
      final cancelled = expectLater(
        operation,
        throwsA(isA<OcrCancelledException>()),
      );
      await entered.future;
      queue.cancelEpubImages(document.activeRevisionId);
      release.complete();
      await cancelled;
      expect(await repo.search(project.id, '知识整理'), isEmpty);
      final result = await queue.enqueueEpubImage(
        revisionId: document.activeRevisionId,
        locator: locator,
        image: image,
      );
      expect(result.text, contains('知识整理'));
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
