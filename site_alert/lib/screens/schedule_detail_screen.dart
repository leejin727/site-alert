import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import 'calendar_screen.dart' show pickDate, isoDate;
import 'home_screen.dart' show SectionHeading;
import 'my_tasks_screen.dart' show daysLeft, ddayText, monthDay, urgentDays;
import 'notice_list_screen.dart' show ErrorView, InfoChip, contentInset;
import 'schedule_form_screen.dart';
import 'task_preview_screen.dart';

/// 일정 날짜의 이름: 시험은 '시험일', 공모전은 '마감일'.
String dateLabel(String kind) => kind == 'exam' ? '시험일' : '마감일';

/// 일정까지 남은 날의 표시: 'D-3', 'D-day', 지났으면 '지남'.
String scheduleDday(int days) => days < 0 ? '지남' : ddayText(days);

/// 할 일·마감의 출처 화면을 엶: 공지는 미리보기, 직접 만든 일정은 일정 상세.
Future<void> openSource(
  BuildContext context,
  ApiClient api,
  TaskSource source, {
  DateTime? today,
}) => Navigator.of(context).push(
  MaterialPageRoute(
    builder: (_) => source.isSchedule
        ? ScheduleDetailScreen(
            api: api,
            scheduleId: source.scheduleId!,
            today: today,
          )
        : TaskPreviewScreen(
            api: api,
            noticeId: source.noticeId!,
            link: source.noticeLink!,
          ),
  ),
);

/// 직접 만든 일정(시험·공모전)의 상세: D-day, 진행률, 단계별 체크리스트.
/// 항목 추가·수정·삭제·완료와 예정일 변경은 바로 서버에 반영.
class ScheduleDetailScreen extends StatefulWidget {
  const ScheduleDetailScreen({
    super.key,
    required this.api,
    required this.scheduleId,
    this.initial,
    this.today,
  });

  final ApiClient api;
  final int scheduleId;
  final ScheduleDetail? initial; // 방금 등록한 일정이면 다시 불러오지 않음
  final DateTime? today; // 테스트용. 없으면 기기의 오늘 날짜

  @override
  State<ScheduleDetailScreen> createState() => _ScheduleDetailScreenState();
}

class _ScheduleDetailScreenState extends State<ScheduleDetailScreen> {
  ScheduleDetail? _detail;
  List<ScheduleTask> _tasks = [];
  String? _error;
  final Set<int> _busy = {}; // 서버에 반영 중인 항목 id
  bool _adding = false;

  DateTime get _today => widget.today ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    if (widget.initial != null) {
      _show(widget.initial!);
    } else {
      _load();
    }
  }

  void _show(ScheduleDetail detail) {
    _detail = detail;
    _tasks = [...detail.tasks];
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final detail = await widget.api.fetchSchedule(widget.scheduleId);
      if (mounted) setState(() => _show(detail));
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  void _replace(ScheduleTask task) {
    final i = _tasks.indexWhere((t) => t.id == task.id);
    if (i >= 0) _tasks[i] = task;
  }

  /// 체크하면 화면을 먼저 바꾸고 서버에 반영. 실패하면 되돌림.
  Future<void> _toggle(ScheduleTask task, bool isDone) async {
    setState(() {
      _busy.add(task.id);
      _replace(task.copyWith(isDone: isDone));
    });
    try {
      await widget.api.setDone(task.id, isDone);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _replace(task));
      _showMessage('반영하지 못했어요: ${e.message}');
    } finally {
      if (mounted) setState(() => _busy.remove(task.id));
    }
  }

  Future<void> _add() async {
    final result = await showScheduleTaskSheet(
      context,
      heading: '항목 추가',
      phases: _detail!.phases,
      today: _today,
    );
    if (result == null || !mounted) return;
    setState(() => _adding = true);
    try {
      await widget.api.addScheduleTask(
        widget.scheduleId,
        title: result.title,
        phase: result.phase,
        scheduledDate: result.date,
      );
      // 단계 안의 자리를 서버가 정하므로 다시 받아 옴
      final detail = await widget.api.fetchSchedule(widget.scheduleId);
      if (mounted) setState(() => _show(detail));
    } on ApiException catch (e) {
      if (mounted) _showMessage('추가하지 못했어요: ${e.message}');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _edit(ScheduleTask task) async {
    final result = await showScheduleTaskSheet(
      context,
      heading: '항목 수정',
      title: task.title,
      date: task.scheduledDate,
      today: _today,
    );
    if (result == null || !mounted) return;
    setState(() => _busy.add(task.id));
    try {
      final updated = await widget.api.updateScheduleTask(
        task.id,
        title: result.title,
        scheduledDate: result.date,
      );
      if (mounted) setState(() => _replace(updated));
    } on ApiException catch (e) {
      if (mounted) _showMessage('수정하지 못했어요: ${e.message}');
    } finally {
      if (mounted) setState(() => _busy.remove(task.id));
    }
  }

  Future<bool> _confirm(String title, String content, String action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _deleteTask(ScheduleTask task) async {
    if (!await _confirm('항목을 삭제할까요?', task.title, '삭제') || !mounted) return;
    setState(() => _busy.add(task.id));
    try {
      await widget.api.deleteTask(task.id);
      if (mounted) setState(() => _tasks.removeWhere((t) => t.id == task.id));
    } on ApiException catch (e) {
      if (mounted) _showMessage('삭제하지 못했어요: ${e.message}');
    } finally {
      if (mounted) setState(() => _busy.remove(task.id));
    }
  }

  Future<void> _editSchedule() async {
    final updated = await Navigator.of(context).push<ScheduleDetail>(
      MaterialPageRoute(
        builder: (_) => ScheduleFormScreen(
          api: widget.api,
          existing: _detail,
          today: widget.today,
        ),
      ),
    );
    if (updated != null && mounted) setState(() => _show(updated));
  }

  Future<void> _deleteSchedule() async {
    final ok = await _confirm(
      '일정을 삭제할까요?',
      '${_detail!.title}\n체크리스트 ${_tasks.length}개도 함께 지워져요.',
      '삭제',
    );
    if (!ok || !mounted) return;
    try {
      await widget.api.deleteSchedule(widget.scheduleId);
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (mounted) _showMessage('삭제하지 못했어요: ${e.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return Scaffold(
      appBar: AppBar(
        title: Text(detail == null ? '일정' : kindLabel(detail.kind)),
        actions: [
          if (detail != null) ...[
            IconButton(
              tooltip: '일정 수정',
              onPressed: _editSchedule,
              icon: const Icon(Icons.edit_outlined),
            ),
            IconButton(
              tooltip: '일정 삭제',
              onPressed: _deleteSchedule,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ],
      ),
      body: _error != null
          ? ErrorView(message: _error!, onRetry: _load)
          : detail == null
          ? const Center(child: CircularProgressIndicator())
          : _buildContent(context, detail),
    );
  }

  Widget _buildContent(BuildContext context, ScheduleDetail detail) {
    final theme = Theme.of(context);
    final today = _today;
    final days = daysLeft(detail.date, today);
    final done = _tasks.where((t) => t.isDone).length;
    // 단계 순서대로, 단계가 없는 항목은 '기타'로 맨 뒤
    final groups = <(String, List<ScheduleTask>)>[
      for (final phase in detail.phases)
        (phase, [..._tasks.where((t) => t.phase == phase)]),
      ('기타', [..._tasks.where((t) => !detail.phases.contains(t.phase))]),
    ];
    return ListView(
      padding: EdgeInsets.symmetric(
        horizontal: contentInset(context),
        vertical: 16,
      ),
      children: [
        Text(detail.title, style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            InfoChip(
              icon: Icons.event,
              urgent: days >= 0 && days <= urgentDays,
              text:
                  '${scheduleDday(days)} · ${dateLabel(detail.kind)} ${monthDay(detail.date)}',
            ),
          ],
        ),
        const SizedBox(height: 12),
        Card(
          margin: EdgeInsets.zero, // 아래 체크리스트 카드와 좌우를 맞춤
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: _tasks.isEmpty
                ? const Text('체크리스트가 비어 있어요')
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${_tasks.length}개 중 $done개 완료',
                              style: theme.textTheme.titleMedium,
                            ),
                          ),
                          Text(
                            '${(done / _tasks.length * 100).round()}%',
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      LinearProgressIndicator(
                        value: done / _tasks.length,
                        minHeight: 8,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ],
                  ),
          ),
        ),
        for (final (phase, tasks) in groups)
          if (tasks.isNotEmpty) ...[
            SectionHeading(phase),
            for (final t in tasks)
              _ChecklistTile(
                key: ValueKey(t.id),
                task: t,
                today: today,
                busy: _busy.contains(t.id),
                onChanged: (v) => _toggle(t, v),
                onEdit: () => _edit(t),
                onDelete: () => _deleteTask(t),
              ),
          ],
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _adding ? null : _add,
            icon: _adding
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add),
            label: const Text('항목 추가'),
          ),
        ),
      ],
    );
  }
}

class _ChecklistTile extends StatelessWidget {
  const _ChecklistTile({
    super.key,
    required this.task,
    required this.today,
    required this.busy,
    required this.onChanged,
    required this.onEdit,
    required this.onDelete,
  });

  final ScheduleTask task;
  final DateTime today;
  final bool busy;
  final ValueChanged<bool> onChanged;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheduled = task.scheduledDate;
    final days = scheduled == null ? null : daysLeft(scheduled, today);
    return Card.outlined(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: busy ? null : onEdit,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(
                value: task.isDone,
                onChanged: busy ? null : (v) => onChanged(v ?? false),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 10),
                    Text(
                      task.title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        decoration: task.isDone
                            ? TextDecoration.lineThrough
                            : null,
                        color: task.isDone
                            ? theme.colorScheme.onSurfaceVariant
                            : null,
                      ),
                    ),
                    const SizedBox(height: 8),
                    InfoChip(
                      icon: Icons.today,
                      urgent: !task.isDone && days != null && days < 0,
                      text: switch (days) {
                        null => '예정일 없음',
                        0 => '오늘 하기',
                        < 0 => '지남 · ${monthDay(scheduled!)}',
                        _ => '${monthDay(scheduled!)}에 하기',
                      },
                    ),
                    const SizedBox(height: 8),
                    const Evidence(text: null, emptyText: '직접 추가'),
                  ],
                ),
              ),
              if (busy)
                const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else ...[
                IconButton(
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: '수정',
                ),
                IconButton(
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline),
                  tooltip: '삭제',
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

typedef ScheduleTaskInput = ({String title, String? phase, String? date});

/// 체크리스트 항목의 제목·예정일(추가할 때는 단계도)을 입력받는 시트. 취소하면 null.
/// [phases]를 주면 단계를 고를 수 있음.
Future<ScheduleTaskInput?> showScheduleTaskSheet(
  BuildContext context, {
  required String heading,
  required DateTime today,
  String title = '',
  String? date,
  List<String>? phases,
}) {
  return showModalBottomSheet<ScheduleTaskInput>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _ScheduleTaskSheet(
      heading: heading,
      title: title,
      date: date,
      phases: phases,
      today: today,
    ),
  );
}

class _ScheduleTaskSheet extends StatefulWidget {
  const _ScheduleTaskSheet({
    required this.heading,
    required this.title,
    required this.date,
    required this.phases,
    required this.today,
  });

  final String heading;
  final String title;
  final String? date;
  final List<String>? phases;
  final DateTime today;

  @override
  State<_ScheduleTaskSheet> createState() => _ScheduleTaskSheetState();
}

class _ScheduleTaskSheetState extends State<_ScheduleTaskSheet> {
  static const _noPhase = '기타';

  late final _title = TextEditingController(text: widget.title);
  late String? _date = widget.date;
  late String _phase = widget.phases?.first ?? _noPhase;

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

  void _submit() {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    Navigator.pop(context, (
      title: title,
      phase: widget.phases == null || _phase == _noPhase ? null : _phase,
      date: _date,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(widget.heading, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          TextField(
            controller: _title,
            autofocus: true,
            decoration: const InputDecoration(labelText: '항목'),
            onChanged: (_) => setState(() {}),
          ),
          if (widget.phases != null) ...[
            const SizedBox(height: 16),
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: [
                for (final p in [...widget.phases!, _noPhase])
                  ButtonSegment(value: p, label: Text(p)),
              ],
              selected: {_phase},
              onSelectionChanged: (s) => setState(() => _phase = s.first),
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(Icons.event),
                  label: Text(_date == null ? '예정일 선택' : '예정일 $_date'),
                ),
              ),
              if (_date != null)
                IconButton(
                  tooltip: '예정일 지우기',
                  onPressed: () => setState(() => _date = null),
                  icon: const Icon(Icons.close),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('취소'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _title.text.trim().isEmpty ? null : _submit,
                child: const Text('확인'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
