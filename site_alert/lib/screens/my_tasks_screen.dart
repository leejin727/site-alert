import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import 'notice_list_screen.dart' show ErrorView, InfoChip, contentInset;
import 'task_preview_screen.dart';
import 'weekly_review_screen.dart';

const urgentDays = 3; // 마감까지 이 일수 이내(D-3 ~ D-day)면 임박으로 강조

/// 마감까지 남은 일수 (오늘 마감 0, 지났으면 음수). 날짜 계산은 기기 날짜 기준으로 앱이 함.
int daysLeft(String isoDate, DateTime today) {
  final due = DateTime.parse(isoDate);
  return DateTime.utc(
    due.year,
    due.month,
    due.day,
  ).difference(DateTime.utc(today.year, today.month, today.day)).inDays;
}

String monthDay(String isoDate) =>
    '${int.parse(isoDate.substring(5, 7))}/${int.parse(isoDate.substring(8, 10))}';

/// '내 할 일': 저장한 할 일을 마감이 가까운 순으로. 완료한 것은 아래 '완료' 묶음에.
class MyTasksScreen extends StatefulWidget {
  const MyTasksScreen({super.key, required this.api, this.today});

  final ApiClient api;
  final DateTime? today; // 테스트용. 없으면 기기의 오늘 날짜

  @override
  State<MyTasksScreen> createState() => _MyTasksScreenState();
}

class _MyTasksScreenState extends State<MyTasksScreen> {
  List<MyTask>? _tasks;
  String? _error;
  final Set<int> _pending = {}; // 완료 체크를 서버에 반영 중인 할 일 id

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final tasks = await widget.api.fetchMyTasks();
      if (mounted) setState(() => _tasks = tasks);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  void _replace(MyTask task) {
    final i = _tasks!.indexWhere((t) => t.id == task.id);
    if (i >= 0) _tasks![i] = task;
  }

  /// 체크하면 화면을 먼저 바꾸고 서버에 반영. 실패하면 되돌림.
  Future<void> _toggle(MyTask task, bool isDone) async {
    setState(() {
      _pending.add(task.id);
      _replace(task.copyWith(isDone: isDone));
    });
    try {
      await widget.api.setDone(task.id, isDone);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _replace(task));
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('반영하지 못했어요: ${e.message}')));
    } finally {
      if (mounted) setState(() => _pending.remove(task.id));
    }
  }

  Future<void> _openNotice(MyTask task) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TaskPreviewScreen(
          api: widget.api,
          noticeId: task.noticeId,
          link: task.noticeLink,
        ),
      ),
    );
    if (mounted) _load(); // 미리보기에서 할 일을 고쳤을 수 있음
  }

  @override
  Widget build(BuildContext context) {
    final tasks = _tasks;
    return Scaffold(
      appBar: AppBar(
        title: const Text('내 할 일'),
        actions: [
          if (kIsWeb) // 마우스로는 당겨서 새로고침이 안 됨
            IconButton(
              tooltip: '새로고침',
              onPressed: _load,
              icon: const Icon(Icons.refresh),
            ),
          TextButton.icon(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => WeeklyReviewScreen(api: widget.api),
              ),
            ),
            icon: const Icon(Icons.insights),
            label: const Text('이번 주 회고'),
          ),
        ],
      ),
      body: _error != null
          ? ErrorView(message: _error!, onRetry: _load)
          : tasks == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(onRefresh: _load, child: _buildList(tasks)),
    );
  }

  Widget _buildList(List<MyTask> tasks) {
    if (tasks.isEmpty) {
      return ListView(
        children: const [
          SizedBox(height: 120),
          Center(
            child: Text(
              "저장한 할 일이 없어요.\n공지에서 '이거 할래'를 눌러 담아 보세요.",
              textAlign: TextAlign.center,
            ),
          ),
        ],
      );
    }
    final today = widget.today ?? DateTime.now();
    final todo = tasks.where((t) => !t.isDone).toList();
    final done = tasks.where((t) => t.isDone).toList();
    Widget tile(MyTask t) => MyTaskTile(
      key: ValueKey(t.id),
      task: t,
      today: today,
      pending: _pending.contains(t.id),
      onChanged: (v) => _toggle(t, v),
      onTap: () => _openNotice(t),
    );
    return ListView(
      padding: EdgeInsets.symmetric(
        horizontal: contentInset(context),
        vertical: 16,
      ),
      children: [
        if (todo.isEmpty)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: Text('남은 할 일을 모두 끝냈어요'),
          ),
        for (final t in todo) tile(t),
        if (done.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 8),
            child: Text(
              '완료 ${done.length}개',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          for (final t in done) tile(t),
        ],
      ],
    );
  }
}

class MyTaskTile extends StatelessWidget {
  const MyTaskTile({
    super.key,
    required this.task,
    required this.today,
    required this.pending,
    required this.onChanged,
    required this.onTap,
  });

  final MyTask task;
  final DateTime today;
  final bool pending;
  final ValueChanged<bool> onChanged;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final deadline = task.deadline;
    final days = deadline?.date == null
        ? null
        : daysLeft(deadline!.date!, today);
    final urgent =
        !task.isDone && days != null && days >= 0 && days <= urgentDays;
    final overdue = !task.isDone && days != null && days < 0;
    final dimmed = task.isDone || overdue;
    final muted = theme.colorScheme.onSurfaceVariant;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      shape: urgent
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: theme.colorScheme.error, width: 1.5),
            )
          : null,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 16, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Checkbox(
                value: task.isDone,
                onChanged: pending ? null : (v) => onChanged(v ?? false),
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
                        decoration: dimmed ? TextDecoration.lineThrough : null,
                        color: dimmed ? muted : null,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      task.noticeTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: muted,
                      ),
                    ),
                    if (!task.isDone &&
                        (task.scheduledDate != null || deadline != null)) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          if (task.scheduledDate != null)
                            InfoChip(
                              icon: Icons.today,
                              text: _scheduleText(task.scheduledDate!),
                            ),
                          if (deadline != null)
                            InfoChip(
                              icon: Icons.event,
                              urgent: urgent,
                              text: _deadlineText(deadline, days),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _scheduleText(String scheduled) =>
      switch (daysLeft(scheduled, today)) {
        0 => '오늘 하기',
        1 => '내일 하기',
        < 0 => '${monthDay(scheduled)}에 하기로 했던 일',
        _ => '${monthDay(scheduled)}에 하기',
      };

  /// 예: 'D-2 · 서류 제출 10/30 18:00', '마감 지남 · 공지 마감(신청) 10/16'
  String _deadlineText(DeadlineInfo deadline, int? days) {
    final dday = switch (days) {
      null => null,
      0 => 'D-day',
      < 0 => '마감 지남',
      _ => 'D-$days',
    };
    final label = task.deadlineFromNotice
        ? '공지 마감(${deadline.label})'
        : deadline.label;
    final date = deadline.date == null ? '날짜 미정' : monthDay(deadline.date!);
    final time = deadline.time == null
        ? ''
        : ' ${deadline.time!.substring(0, 5)}';
    return [?dday, '$label $date$time'].join(' · ');
  }
}
