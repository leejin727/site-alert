import 'package:flutter/material.dart';

import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../models.dart';
import 'notice_list_screen.dart' show ErrorView, contentInset;

/// '이거 할래' 미리보기: 화면을 열면 서버가 할 일을 draft로 만들고(POST), 고친 내용은 바로 반영(PATCH).
/// '저장'을 눌러야 confirmed가 되어 '담은 할 일'이 됨 (true를 돌려주면 목록에서 안내 표시).
/// 저장하지 않고 나가면 draft는 서버가 24시간 뒤 정리.
class TaskPreviewScreen extends StatefulWidget {
  const TaskPreviewScreen({
    super.key,
    required this.api,
    required this.noticeId,
    required this.link,
  });

  final ApiClient api;
  final int noticeId;
  final String link; // 공지 원문 주소 (로딩·오류 중에도 '원문 보기'에 씀)

  @override
  State<TaskPreviewScreen> createState() => _TaskPreviewScreenState();
}

class _TaskPreviewScreenState extends State<TaskPreviewScreen> {
  TaskPreview? _preview;
  String? _error;
  final List<TaskItem> _tasks = [];
  final Set<int> _busy = {}; // 서버에 반영 중인 할 일 id
  bool _adding = false;
  bool _confirming = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _preview = null;
      _error = null;
    });
    try {
      final preview = await widget.api.startTasks(widget.noticeId);
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _tasks
          ..clear()
          ..addAll(preview.tasks);
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _confirm() async {
    setState(() => _confirming = true);
    try {
      await widget.api.confirmTasks(widget.noticeId);
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) _showMessage('저장하지 못했어요: ${e.message}');
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _openLink() async {
    final ok = await launchUrl(
      Uri.parse(widget.link),
      mode: LaunchMode.externalApplication,
    ).catchError((_) => false);
    if (!ok && mounted) _showMessage('원문을 열 수 없어요: ${widget.link}');
  }

  Future<void> _edit(TaskItem task) async {
    final result = await showTaskEditSheet(
      context,
      title: task.title,
      note: task.note,
      heading: '할 일 수정',
    );
    if (result == null || !mounted) return;
    if (result.title == task.title && result.note == task.note) return;
    setState(() => _busy.add(task.id));
    try {
      final updated = await widget.api.updateTask(
        task.id,
        title: result.title,
        note: result.note,
      );
      if (!mounted) return;
      setState(() {
        final i = _tasks.indexWhere((t) => t.id == task.id);
        if (i >= 0) _tasks[i] = updated;
      });
    } on ApiException catch (e) {
      if (mounted) _showMessage('수정하지 못했어요: ${e.message}'); // 화면은 고치기 전 값 그대로
    } finally {
      if (mounted) setState(() => _busy.remove(task.id));
    }
  }

  Future<void> _add() async {
    final result = await showTaskEditSheet(context, heading: '할 일 추가');
    if (result == null || !mounted) return;
    setState(() => _adding = true);
    try {
      final added = await widget.api.addTask(
        widget.noticeId,
        title: result.title,
        note: result.note,
      );
      if (mounted) setState(() => _tasks.add(added));
    } on ApiException catch (e) {
      if (mounted) _showMessage('추가하지 못했어요: ${e.message}');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _delete(TaskItem task) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('할 일을 삭제할까요?'),
        content: Text(task.title),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
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

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    final busy = _busy.isNotEmpty || _adding || _confirming;
    final inset = contentInset(context);
    return Scaffold(
      appBar: AppBar(title: const Text('이거 할래')),
      body: _error != null
          ? ErrorView(message: _error!, onRetry: _load)
          : preview == null
          ? const _LoadingView()
          : _buildContent(context, preview),
      // 원문 링크는 로딩·오류 중에도 항상 보이게
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(inset, 8, inset, 16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _openLink,
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('원문 보기'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
              ),
              if (preview != null) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    // 반영 중인 수정이 끝난 뒤에만 저장
                    onPressed: busy ? null : _confirm,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    child: _confirming
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('저장'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, TaskPreview preview) {
    final theme = Theme.of(context);
    final deadlineLabels = {for (final d in preview.deadlines) d.id: d.label};
    final unclear = preview.unclearLabels;
    return ListView(
      padding: EdgeInsets.symmetric(
        horizontal: contentInset(context),
        vertical: 16,
      ),
      children: [
        Text(preview.title, style: theme.textTheme.titleLarge),
        if (unclear.isNotEmpty) ...[
          const SizedBox(height: 12),
          _UnclearBanner(labels: unclear),
        ],
        const _SectionTitle('마감'),
        if (preview.deadlines.isEmpty) const Text('공지에 적힌 마감이 없어요'),
        for (final d in preview.deadlines) _DeadlineTile(deadline: d),
        const _SectionTitle('신청 방식'),
        Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              preview.applyMethod ?? '불명확',
              style: theme.textTheme.titleSmall,
            ),
            if (preview.applyMethod == null || preview.applyMethod == '불명확')
              const _Tag('확인 필요'),
          ],
        ),
        const SizedBox(height: 4),
        Evidence(text: preview.applyMethodEvidence),
        const _SectionTitle('할 일'),
        if (_tasks.isEmpty) const Text('공지에서 찾은 할 일이 없어요. 직접 추가할 수 있어요.'),
        for (final t in _tasks)
          _TaskTile(
            key: ValueKey(t.id),
            task: t,
            deadlineLabel: deadlineLabels[t.deadlineId],
            busy: _busy.contains(t.id),
            onTap: () => _edit(t),
            onDelete: () => _delete(t),
          ),
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
            label: const Text('할 일 추가'),
          ),
        ),
      ],
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          const Text('할 일을 정리하는 중…'),
          const SizedBox(height: 4),
          Text(
            '처음 정리하는 공지는 10초쯤 걸려요',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleMedium
            ?.copyWith(fontWeight: FontWeight.bold),
      ),
    );
  }
}

/// 원문 근거 문장. 근거가 없으면 그렇다고 표시.
class Evidence extends StatelessWidget {
  const Evidence({super.key, required this.text, this.emptyText = '근거 문장 없음'});

  final String? text;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: theme.colorScheme.outlineVariant, width: 3),
        ),
      ),
      child: Text(text == null ? emptyText : '근거: $text', style: style),
    );
  }
}

class _DeadlineTile extends StatelessWidget {
  const _DeadlineTile({required this.deadline});

  final DeadlineInfo deadline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '${deadline.label} · ${deadline.when}',
                style: theme.textTheme.titleSmall,
              ),
              if (deadline.yearCorrected) const _Tag('연도 자동 보정'),
              if (deadline.confidence == '낮음') const _Tag('확인 필요'),
            ],
          ),
          const SizedBox(height: 4),
          Evidence(text: deadline.evidence),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: scheme.onTertiaryContainer),
      ),
    );
  }
}

class _UnclearBanner extends StatelessWidget {
  const _UnclearBanner({required this.labels});

  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, color: scheme.onTertiaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '공지에서 확인하지 못한 항목이 있어요: ${labels.join(', ')}\n원문에서 직접 확인해 주세요.',
              style: TextStyle(color: scheme.onTertiaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({
    super.key,
    required this.task,
    required this.busy,
    required this.onTap,
    required this.onDelete,
    this.deadlineLabel,
  });

  final TaskItem task;
  final bool busy;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final String? deadlineLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final meta = [
      if (deadlineLabel != null) '$deadlineLabel 마감까지',
      if (task.isDone) '완료한 할 일',
    ];
    return Card.outlined(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: busy ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(task.title, style: theme.textTheme.titleSmall),
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
                      onPressed: onTap,
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
              if (task.note != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8, bottom: 4),
                  child: Text(
                    '메모: ${task.note}',
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              if (meta.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    meta.join(' · '),
                    style: theme.textTheme.labelMedium,
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Evidence(text: task.evidence, emptyText: '직접 추가한 할 일'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 할 일 제목·메모를 입력받는 시트. 취소하면 null.
Future<({String title, String? note})?> showTaskEditSheet(
  BuildContext context, {
  required String heading,
  String title = '',
  String? note,
}) {
  return showModalBottomSheet<({String title, String? note})>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) =>
        _TaskEditSheet(heading: heading, title: title, note: note),
  );
}

class _TaskEditSheet extends StatefulWidget {
  const _TaskEditSheet({required this.heading, required this.title, this.note});

  final String heading;
  final String title;
  final String? note;

  @override
  State<_TaskEditSheet> createState() => _TaskEditSheetState();
}

class _TaskEditSheetState extends State<_TaskEditSheet> {
  late final _title = TextEditingController(text: widget.title);
  late final _note = TextEditingController(text: widget.note ?? '');

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  void _submit() {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    final note = _note.text.trim();
    Navigator.pop(context, (title: title, note: note.isEmpty ? null : note));
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
            decoration: const InputDecoration(labelText: '할 일'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _note,
            decoration: const InputDecoration(labelText: '메모 (선택)'),
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
