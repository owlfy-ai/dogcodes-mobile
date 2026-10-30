import 'package:dogcodes_app/l10n/strings.dart';
import 'package:flutter/material.dart';
import '../../ui/theme.dart';

/// A choice offered by a question field: `enum` values or `oneOf`/`anyOf`
/// entries with `const` and an optional `title`.
class _Choice {
  const _Choice(this.value, this.label);
  final Object? value;
  final String label;
}

List<_Choice>? _choices(Map schema) {
  final list = schema['oneOf'] ?? schema['anyOf'];
  if (list is List) {
    return [
      for (final o in list)
        if (o is Map && o.containsKey('const'))
          _Choice(o['const'], '${o['title'] ?? o['const']}'),
    ];
  }
  if (schema['enum'] is List) {
    return [for (final v in schema['enum'] as List) _Choice(v, '$v')];
  }
  return null;
}

/// One line per answered field, in the question's own words.
List<String> answerSummary(Map? form, Map? answer) {
  if (answer == null) return const [];
  if (answer['cancelled'] == true) return [tr("已取消回答")];
  final props = (form?['schema'] as Map?)?['properties'] as Map? ?? const {};
  final values = answer['values'] as Map? ?? const {};
  String label(Map? field, Object? value) {
    if (value is bool) return value ? tr("是") : tr("否");
    final choices = field == null
        ? null
        : _choices(
            field['type'] == 'array' ? field['items'] as Map? ?? {} : field,
          );
    if (value is List) return value.map((v) => label(field, v)).join('、');
    return choices?.where((c) => c.value == value).firstOrNull?.label ??
        '$value';
  }

  return [
    for (final MapEntry(:key, :value) in values.entries)
      '${(props[key] as Map?)?['title'] ?? key}：${label(props[key] as Map?, value)}',
  ];
}

/// Whether every field uses a type this form can render; otherwise the
/// question is answered on the PC.
bool supportsQuestion(Map? form) {
  final props = (form?['schema'] as Map?)?['properties'];
  if (props is! Map || props.isEmpty) return false;
  for (final field in props.values) {
    if (field is! Map) return false;
    final type = field['type'] ?? 'string';
    if (type == 'array') {
      final items = field['items'];
      if (items is! Map || _choices(items) == null) return false;
    } else if (!['string', 'boolean', 'integer', 'number'].contains(type)) {
      return false;
    }
  }
  return true;
}

/// Mobile rendering of the PC's structured question (JSON-schema subset that
/// the PC validates again before delivering the answer).
class QuestionFormView extends StatefulWidget {
  const QuestionFormView({
    super.key,
    required this.form,
    required this.enabled,
    required this.onSubmit,
  });
  final Map<String, dynamic> form;
  final bool enabled;
  final void Function(Map<String, dynamic> answer) onSubmit;
  @override
  State<QuestionFormView> createState() => _QuestionFormViewState();
}

class _QuestionFormViewState extends State<QuestionFormView> {
  final values = <String, Object?>{};
  final text = <String, TextEditingController>{};
  String? error;

  Map get schema => widget.form['schema'] as Map;
  Map get props => schema['properties'] as Map;
  List get required => schema['required'] as List? ?? const [];

  @override
  void dispose() {
    for (final c in text.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _controller(String key) => text.putIfAbsent(
    key,
    () => TextEditingController()..addListener(() => setState(() {})),
  );

  Object? _value(String key, Map field) {
    final type = field['type'] ?? 'string';
    if (_choices(field) != null || type == 'boolean' || type == 'array') {
      return values[key];
    }
    final raw = text[key]?.text.trim() ?? '';
    if (raw.isEmpty) return null;
    if (type == 'integer') return int.tryParse(raw) ?? raw;
    if (type == 'number') return num.tryParse(raw) ?? raw;
    return text[key]!.text;
  }

  void submit() {
    final result = <String, dynamic>{};
    for (final e in props.entries) {
      final key = '${e.key}';
      final v = _value(key, e.value as Map);
      if (v == null || (v is List && v.isEmpty && !required.contains(key))) {
        if (required.contains(key)) {
          setState(() => error = tr("请回答所有必填问题"));
          return;
        }
        continue;
      }
      result[key] = v;
    }
    setState(() => error = null);
    widget.onSubmit({'cancelled': false, 'values': result});
  }

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    final c = context.dc;
    final children = <Widget>[];
    for (final e in props.entries) {
      final key = '${e.key}';
      final field = e.value as Map;
      final type = field['type'] ?? 'string';
      final title =
          '${field['title'] ?? key}${required.contains(key) ? '' : tr("（可选）")}';
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Text(title, style: Theme.of(context).textTheme.titleMedium),
        ),
      );
      if (field['description'] is String) {
        children.add(
          Text(
            field['description'] as String,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        );
      }
      final choices = type == 'array'
          ? _choices(field['items'] as Map)
          : _choices(field);
      if (type == 'array') {
        final selected = (values[key] as List?) ?? const [];
        for (final o in choices!) {
          children.add(
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              activeColor: c.accent,
              checkColor: c.onAccent,
              controlAffinity: ListTileControlAffinity.leading,
              value: selected.contains(o.value),
              title: Text(o.label),
              onChanged: widget.enabled
                  ? (on) => setState(
                      () => values[key] = [
                        ...selected.where((v) => v != o.value),
                        if (on == true) o.value,
                      ],
                    )
                  : null,
            ),
          );
        }
      } else if (choices != null) {
        for (final o in choices) {
          final selected = values[key] == o.value;
          children.add(
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              enabled: widget.enabled,
              onTap: () => setState(() => values[key] = o.value),
              leading: Icon(
                selected ? Icons.radio_button_checked : Icons.radio_button_off,
                color: selected ? c.accent : c.secondary,
              ),
              title: Text(o.label),
            ),
          );
        }
      } else if (type == 'boolean') {
        children.add(
          Row(
            children: [
              for (final (v, label) in [(true, tr("是")), (false, tr("否"))])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(label),
                    selected: values[key] == v,
                    selectedColor: c.surface,
                    side: BorderSide(
                      color: values[key] == v ? c.accent : c.line,
                    ),
                    onSelected: widget.enabled
                        ? (_) => setState(() => values[key] = v)
                        : null,
                  ),
                ),
            ],
          ),
        );
      } else {
        children.add(
          TextField(
            controller: _controller(key),
            enabled: widget.enabled,
            obscureText: field['writeOnly'] == true,
            maxLines: field['writeOnly'] == true ? 1 : 4,
            minLines: 1,
            keyboardType: type == 'string'
                ? TextInputType.text
                : const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(hintText: tr("输入你的答案…")),
          ),
        );
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ...children,
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              error!,
              style: TextStyle(color: c.removed, fontSize: 13),
            ),
          ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: widget.enabled
                    ? () => widget.onSubmit({'cancelled': true, 'values': {}})
                    : null,
                child: Text(tr("取消回答")),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton(
                onPressed: widget.enabled ? submit : null,
                child: Text(tr("发送回答")),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
