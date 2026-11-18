import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import 'calendar_screen.dart' show pickDate, isoDate;
import 'notice_list_screen.dart' show contentInset;
import 'schedule_detail_screen.dart' show dateLabel;

/// 일정 등록(시험·공모전) 또는 수정. 끝나면 서버가 돌려준 일정을 가지고 닫힘.
/// 수정([existing])에서는 제목과 날짜만 바꿀 수 있음.
class ScheduleFormScreen extends StatefulWidget {
  const ScheduleFormScreen({
    super.key,
    required this.api,
    this.existing,
    this.today,
  });

  final ApiClient api;
  final ScheduleDetail? existing;
  final DateTime? today; // 테스트용. 없으면 기기의 오늘 날짜

  @override
  State<ScheduleFormScreen> createState() => _ScheduleFormScreenState();
}

class _ScheduleFormScreenState extends State<ScheduleFormScreen> {
  late String _kind = widget.existing?.kind ?? 'exam';
  late final _title = TextEditingController(text: widget.existing?.title);
  late String? _date = widget.existing?.date;
  bool _useChecklist = true;
  bool _saving = false;

  bool get _editing => widget.existing != null;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await pickDate(
      context,
      initial: _date == null ? null : DateTime.parse(_date!),
      today: widget.today,
    );
    if (picked != null && mounted) setState(() => _date = isoDate(picked));
  }

  Future<void> _submit() async {
    setState(() => _saving = true);
    try {
      final title = _title.text.trim();
      final saved = _editing
          ? await widget.api.updateSchedule(
              widget.existing!.id,
              title: title,
              date: _date!,
            )
          : await widget.api.createSchedule(
              kind: _kind,
              title: title,
              date: _date!,
              useChecklist: _useChecklist,
            );
      if (mounted) Navigator.of(context).pop(saved);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('${_editing ? '저장' : '등록'}하지 못했어요: ${e.message}'),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ready = _title.text.trim().isNotEmpty && _date != null;
    return Scaffold(
      appBar: AppBar(title: Text(_editing ? '일정 수정' : '일정 추가')),
      body: ListView(
        padding: EdgeInsets.symmetric(
          horizontal: contentInset(context),
          vertical: 16,
        ),
        children: [
          if (!_editing) ...[
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: [
                for (final kind in const ['exam', 'contest'])
                  ButtonSegment(value: kind, label: Text(kindLabel(kind))),
              ],
              selected: {_kind},
              onSelectionChanged: (s) => setState(() => _kind = s.first),
            ),
            const SizedBox(height: 16),
          ],
          TextField(
            controller: _title,
            decoration: const InputDecoration(
              labelText: '제목',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _pickDate,
            icon: const Icon(Icons.event),
            label: Text(
              _date == null
                  ? '${dateLabel(_kind)} 선택'
                  : '${dateLabel(_kind)} $_date',
            ),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
          ),
          const SizedBox(height: 8),
          if (_editing)
            Text(
              '날짜를 바꾸면 완료하지 않은 기본 항목의 예정일을 다시 계산해요',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            )
          else
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('기본 체크리스트로 시작'),
              value: _useChecklist,
              onChanged: (v) => setState(() => _useChecklist = v),
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving || !ready ? null : _submit,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(_editing ? '저장' : '등록'),
          ),
        ],
      ),
    );
  }
}
