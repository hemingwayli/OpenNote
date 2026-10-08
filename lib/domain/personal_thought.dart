import 'dart:convert';

/// 一条个人思考的身份与内容；顺序由卡片中的列表保存。
class PersonalThought {
  const PersonalThought({required this.id, required this.text});

  final String id;
  final String text;

  Map<String, Object?> toJson() => {'id': id, 'text': text};

  @override
  bool operator ==(Object other) =>
      other is PersonalThought && other.id == id && other.text == text;

  @override
  int get hashCode => Object.hash(id, text);
}

List<PersonalThought> legacyPersonalThoughts(String cardId, String note) =>
    note.isEmpty
    ? const []
    : [PersonalThought(id: '$cardId:thought', text: note)];

String personalThoughtsText(Iterable<PersonalThought> thoughts) =>
    thoughts.map((thought) => thought.text).join('\n\n');

void _validateThoughts(Iterable<PersonalThought> thoughts) {
  final ids = <String>{};
  for (final thought in thoughts) {
    if (thought.id.trim().isEmpty || !ids.add(thought.id)) {
      throw const FormatException('个人思考的标识为空或重复');
    }
  }
}

String encodePersonalThoughts(List<PersonalThought> thoughts) {
  _validateThoughts(thoughts);
  return jsonEncode(thoughts.map((thought) => thought.toJson()).toList());
}

List<PersonalThought> decodePersonalThoughts(String value) {
  final decoded = jsonDecode(value);
  if (decoded is! List) throw const FormatException('个人思考必须是列表');
  final thoughts = <PersonalThought>[];
  for (final item in decoded) {
    if (item is! Map || item['id'] is! String || item['text'] is! String) {
      throw const FormatException('个人思考的内容格式无效');
    }
    thoughts.add(PersonalThought(id: item['id'], text: item['text']));
  }
  _validateThoughts(thoughts);
  return List.unmodifiable(thoughts);
}
