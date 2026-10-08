import '../theme/open_note_icon.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/open_note_theme.dart';

import '../../data/open_note_repository.dart';
import '../../domain/models.dart';

class SearchDialog extends StatefulWidget {
  const SearchDialog({
    super.key,
    required this.repository,
    required this.projectId,
  });
  final OpenNoteRepository repository;
  final String projectId;
  @override
  State<SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<SearchDialog> {
  final _input = TextEditingController();
  Timer? _timer;
  int _generation = 0;
  List<SearchHit> _hits = [];
  bool _loading = false;
  String? _error;

  Future<void> _search(String query) async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final hits = query.trim().isEmpty
          ? <SearchHit>[]
          : await widget.repository.search(widget.projectId, query.trim());
      if (mounted && generation == _generation) setState(() => _hits = hits);
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _error = '$error');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    content: SizedBox(
      width: 600,
      height: 430,
      child: Column(
        children: [
          TextField(
            key: const Key('search-input'),
            controller: _input,
            autofocus: true,
            decoration: const InputDecoration(
              prefixIcon: OpenNoteIcon(Icons.search),
              hintText: '搜索',
            ),
            onChanged: (value) {
              _timer?.cancel();
              _timer = Timer(
                const Duration(milliseconds: 180),
                () => unawaited(_search(value)),
              );
            },
            onSubmitted: _search,
          ),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            Text(_error!, style: const TextStyle(color: Colors.red)),
          const SizedBox(height: 16),
          Expanded(
            child: _hits.isEmpty
                ? Center(
                    child: _input.text.isEmpty || _loading || _error != null
                        ? const SizedBox.shrink()
                        : const Text(
                            '没有找到结果',
                            style: TextStyle(color: OpenNoteTokens.secondary),
                          ),
                  )
                : ListView.builder(
                    itemCount: _hits.length,
                    itemBuilder: (context, index) {
                      final hit = _hits[index];
                      final begin = (hit.start - 30).clamp(0, hit.text.length);
                      final end = (hit.end + 60).clamp(begin, hit.text.length);
                      final cardTitle = hit.text.split('\n').first;
                      var excerpt = hit.text.substring(begin, end);
                      if (hit.kind == SearchHitKind.card &&
                          excerpt.startsWith('$cardTitle\n')) {
                        excerpt = excerpt.substring(cardTitle.length + 1);
                      }
                      return ListTile(
                        key: ValueKey('search-result-$index'),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        titleAlignment: ListTileTitleAlignment.top,
                        leading: OpenNoteIcon(
                          hit.kind == SearchHitKind.card
                              ? Icons.sticky_note_2_outlined
                              : hit.epubLocator == null
                              ? Icons.picture_as_pdf_outlined
                              : Icons.menu_book_outlined,
                        ),
                        title: Text(
                          hit.kind == SearchHitKind.card
                              ? cardTitle
                              : hit.epubLocator == null
                              ? '原文 · 第 ${(hit.pageIndex ?? 0) + 1} 页'
                              : '原文 · ${hit.epubLocator!.href.split('/').last}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 16,
                            height: 1.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            excerpt.replaceAll('\n', ' ').trim(),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              height: 1.6,
                              color: OpenNoteTokens.secondary,
                            ),
                          ),
                        ),
                        onTap: () => Navigator.pop(context, hit),
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}
