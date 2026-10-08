import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opennote/data/open_note_repository.dart';
import 'package:opennote/verification/performance_check.dart';
import 'package:pdfrx/pdfrx.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('fixture hash worker可以发送路径且与实际清单一致', () async {
    final fixture = File('tools/verification/fixtures/long-book-1000.pdf')
        .absolute;
    final manifest = jsonDecode(
      await File('tools/verification/fixtures/manifest.json').readAsString(),
    ) as Map;
    expect(await hashPerformanceFixture(fixture.path), manifest['sha256']);
  });
  test('真实1000页逐页原生提取、正式API5000卡片、500节点和中文短检索', () async {
    final fixture = File('tools/verification/fixtures/long-book-1000.pdf')
        .absolute;
    expect(
      fixture.existsSync(),
      isTrue,
      reason: '先运行 generate_capacity_pdf.py',
    );
    final dll = File('build/windows/x64/runner/Release/pdfium.dll');
    if (dll.existsSync()) Pdfrx.pdfiumModulePath = dll.absolute.path;
    await pdfrxInitialize();
    final directory = await Directory.systemTemp.createTemp(
      'opennote-capacity-',
    );
    final repo = await OpenNoteRepository.open(rootPath: directory.path);
    try {
      final dataset = await prepareCapacityDataset(repo, fixture.path);
      expect(dataset.report['actualPdfPages'], 1000);
      expect(dataset.report['persistedNativeTextPages'], 1000);
      expect(dataset.report['actualCards'], 5000);
      expect(dataset.snapshot.nodes.length, 500);
      expect(dataset.snapshot.edges.length, 100);
      expect(repo.undoEntryCount, greaterThanOrEqualTo(5100));
      final queries = <Map<String, Object?>>[];
      for (final query in ['知', '知识', '中文']) {
        final watch = Stopwatch()..start();
        final hits = await repo.search(dataset.project.id, query, limit: 100);
        watch.stop();
        expect(hits.length, 100);
        queries.add({
          'query': query,
          'elapsedMs': watch.elapsedMicroseconds / 1000,
          'hits': hits.length,
        });
      }
      final last = await repo.loadTextLayers(
        dataset.document.activeRevisionId,
        pageIndex: 999,
      );
      expect(last.single.text, contains('1000'));
      expect(last.single.fragments.length, greaterThan(500));
      final report = File('tools/verification/capacity-debug-report.json');
      await report.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'mode': 'Flutter tester debug，非Release性能验收',
          'capturedAt': DateTime.now().toUtc().toIso8601String(),
          'dataset': dataset.report,
          'queries': queries,
          'undoEntries': repo.undoEntryCount,
        }),
        encoding: utf8,
        flush: true,
      );
    } finally {
      await repo.close();
      await directory.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
