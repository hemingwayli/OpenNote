import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'ui/theme/open_note_theme.dart';

import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:material_ui/material_ui.dart' as material_ui;
import 'package:pdfrx/pdfrx.dart';

import 'data/open_note_repository.dart';
import 'ui/home/app_shell.dart';
import 'verification/offline_check.dart';
import 'verification/epub_package_check.dart';
import 'verification/performance_check.dart';
import 'verification/scan_book_check.dart';
import 'verification/startup_check.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(const [
      'Source Han Sans CN / 思源黑体',
    ], await rootBundle.loadString('assets/fonts/source-han-sans/LICENSE.txt'));
  });
  final dataArgument = arguments
      .where((a) => a.startsWith('--data-dir='))
      .firstOrNull;
  final verification = arguments
      .where((a) => a.startsWith('--verify-fixtures='))
      .firstOrNull;
  final scanBook = arguments
      .where((a) => a.startsWith('--verify-scan-book='))
      .firstOrNull;
  final performance = arguments.contains('--verify-performance');
  final epubBook = arguments
      .where((a) => a.startsWith('--verify-epub-book='))
      .firstOrNull;
  if (epubBook != null) {
    final report = arguments
        .where((a) => a.startsWith('--verify-report='))
        .firstOrNull;
    if (dataArgument == null || report == null || verification == null) {
      throw ArgumentError(
        'EPUB 候选验收必须指定独立 --data-dir、--verify-fixtures 和 --verify-report',
      );
    }
    runApp(
      MaterialApp(
        theme: openNoteTheme(),
        home: EpubPackageCheck(
          startup: _open(dataArgument.substring('--data-dir='.length)),
          sourcePath: epubBook.substring('--verify-epub-book='.length),
          fixtureDirectory: verification.substring('--verify-fixtures='.length),
          reportPath: report.substring('--verify-report='.length),
        ),
      ),
    );
    return;
  }
  if (arguments.contains('--verify-startup')) {
    final report = arguments
        .where((a) => a.startsWith('--verify-report='))
        .firstOrNull;
    if (dataArgument == null || report == null) {
      throw ArgumentError('启动计时必须指定独立 --data-dir 和 --verify-report');
    }
    final probe = StartupCheck(report.substring('--verify-report='.length));
    final repository = await _open(
      dataArgument.substring('--data-dir='.length),
    );
    final project = (await repository.listProjects()).firstOrNull;
    runApp(
      OpenNoteApp(
        startup: Future.value(repository),
        startupCheck: probe,
        diagnosticProjectId: project?.id,
      ),
    );
    return;
  }
  if (verification != null || scanBook != null || performance) {
    final report = arguments
        .where((a) => a.startsWith('--verify-report='))
        .firstOrNull;
    if (dataArgument == null || report == null) {
      throw ArgumentError('离线自检必须指定 --data-dir 和 --verify-report，不使用默认资料库');
    }
    if (performance && verification == null) {
      throw ArgumentError('性能验证必须提供 --verify-fixtures');
    }
    final startup = _open(dataArgument.substring('--data-dir='.length));
    if (performance) {
      await runPerformanceCheck(
        startup: startup,
        fixtureDirectory: verification!.substring('--verify-fixtures='.length),
        reportPath: report.substring('--verify-report='.length),
      );
      return;
    }
    runApp(const OfflineCheckScreen());
    if (scanBook != null) {
      await runScanBookCheck(
        startup: startup,
        sourcePath: scanBook.substring('--verify-scan-book='.length),
        reportPath: report.substring('--verify-report='.length),
        resumeExisting: arguments.contains('--verify-existing'),
      );
      return;
    }
    await runOfflineCheck(
      startup: startup,
      fixtureDirectory: verification!.substring('--verify-fixtures='.length),
      reportPath: report.substring('--verify-report='.length),
      auditExisting: arguments.contains('--verify-existing'),
    );
    return;
  }
  runApp(
    OpenNoteApp(startup: _open(dataArgument?.substring('--data-dir='.length))),
  );
}

Future<OpenNoteRepository> _open(String? rootPath) async {
  await pdfrxFlutterInitialize();
  return OpenNoteRepository.open(rootPath: rootPath);
}

class OpenNoteApp extends StatelessWidget {
  const OpenNoteApp({
    super.key,
    required this.startup,
    this.startupCheck,
    this.diagnosticProjectId,
  });
  final Future<OpenNoteRepository> startup;
  final StartupCheck? startupCheck;

  /// 显式启动计时使用指定项目；普通启动始终进入项目首页。
  final String? diagnosticProjectId;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'OpenNote',
    debugShowCheckedModeBanner: false,
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      material_ui.GlobalMaterialLocalizations.delegate,
    ],
    theme: openNoteTheme(),
    builder: (context, child) =>
        material_ui.Theme(data: material_ui.ThemeData.light(), child: child!),
    home: FutureBuilder<OpenNoteRepository>(
      future: startup,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: SelectableText('无法打开本机资料库\n${snapshot.error}'),
              ),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return OpenNoteShell(
          repository: snapshot.data!,
          initialProjectId: diagnosticProjectId,
          onWorkspaceReady: startupCheck?.workspaceReady,
          onInitialPdfReady: startupCheck?.initialPdfReady,
        );
      },
    ),
  );
}
