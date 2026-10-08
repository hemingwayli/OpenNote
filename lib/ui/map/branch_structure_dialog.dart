import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/models.dart';

class BranchStructureResult {
  const BranchStructureResult(this.kind, this.resetDescendants);
  final MapLayoutKind? kind;
  final bool resetDescendants;
}

class BranchStructureDialog extends StatefulWidget {
  const BranchStructureDialog({
    super.key,
    required this.kind,
    required this.selectionCount,
  });
  final MapLayoutKind? kind;
  final int selectionCount;
  @override
  State<BranchStructureDialog> createState() => _BranchStructureDialogState();
}

class _BranchStructureDialogState extends State<BranchStructureDialog> {
  late String _kind = widget.kind?.name ?? 'inherit';
  bool _reset = false;
  @override
  Widget build(BuildContext context) => Dialog(
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 440,
        maxHeight: math.max(240, MediaQuery.sizeOf(context).height - 80),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '分支结构',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            const SizedBox(height: 16),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    Text(
                      '应用到所选 ${widget.selectionCount} 个主题的子树。内层已设置的结构会继续保留。',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      key: const ValueKey('branch-structure-choice'),
                      initialValue: _kind,
                      decoration: const InputDecoration(labelText: '结构'),
                      items: [
                        const DropdownMenuItem(
                          value: 'inherit',
                          child: Text('跟随上层结构'),
                        ),
                        for (final kind in MapLayoutKind.values)
                          DropdownMenuItem(
                            value: kind.name,
                            child: Text(kind.label),
                          ),
                      ],
                      onChanged: (v) {
                        if (v != null) setState(() => _kind = v);
                      },
                    ),
                    const SizedBox(height: 12),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _reset,
                      title: const Text('同时重置内层分支结构'),
                      onChanged: (v) => setState(() => _reset = v!),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.pop(
                    context,
                    BranchStructureResult(
                      _kind == 'inherit'
                          ? null
                          : MapLayoutKind.values.byName(_kind),
                      _reset,
                    ),
                  ),
                  child: const Text('保存'),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
