import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import 'my_tasks_screen.dart'
    show MyTaskTile, TaskChecking, daysLeft, ddayText, monthDay;
import 'notice_list_screen.dart'
    show ErrorView, NoticeCardView, contentInset, noticeRefreshInterval;
import 'schedule_detail_screen.dart' show openSource;
import 'task_preview_screen.dart';
import 'weekly_review_screen.dart';
import '../theme.dart';

const homeNoticeCount = 3; // '새 공지'에 보여줄 개수

/// 오늘 할 일: 예정일이 오늘인 것(완료 포함)과, 예정일이 지났는데 미완료인 것.
List<MyTask> todayTasks(List<MyTask> tasks, DateTime today) => sortTodayTasks([
  for (final t in tasks)
    if (t.scheduledDate != null)
      if (switch (daysLeft(t.scheduledDate!, today)) {
        0 => true,
        < 0 => !t.isDone,
        _ => false,
      })
        t,
]);

/// 미완료가 위, 그 안에서는 예정일이 빠른 순 (같으면 받은 순서 그대로).
List<MyTask> sortTodayTasks(List<MyTask> tasks) {
  final indexed = tasks.indexed.toList();
  indexed.sort((a, b) {
    if (a.$2.isDone != b.$2.isDone) return a.$2.isDone ? 1 : -1;
    final byDate = a.$2.scheduledDate!.compareTo(b.$2.scheduledDate!);
    return byDate != 0 ? byDate : a.$1.compareTo(b.$1);
  });
  return [for (final (_, t) in indexed) t];
}

/// 가장 가까운 마감: 미완료 할 일의 마감 중 오늘 이후 가장 가까운 것. 없으면 null.
MyTask? nearestDeadline(List<MyTask> tasks, DateTime today) {
  String key(MyTask t) => '${t.deadline!.date} ${t.deadline!.time ?? '99'}';
  MyTask? nearest;
  for (final t in tasks) {
    final date = t.deadline?.date;
    if (t.isDone || date == null || daysLeft(date, today) < 0) continue;
    if (nearest == null || key(t).compareTo(key(nearest)) < 0) nearest = t;
  }
  return nearest;
}

/// 홈: 요약(가장 가까운 마감 · 오늘 할 일 · 이번 주 완료율), 오늘 할 일 목록, 새 공지.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.api, this.today});

  final ApiClient api;
  final DateTime? today; // 테스트용. 없으면 기기의 오늘 날짜

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TaskChecking<HomeScreen> {
  // 불러온 시점의 '오늘 할 일'. 지난 할 일을 체크해도 다시 불러올 때까지는 목록에 남겨 되돌릴 수 있게 함
  Set<int> _todayIds = {};
  WeeklyReview? _review;
  List<NoticeCard> _notices = [];
  String? _error;

  @override
  ApiClient get taskApi => widget.api;

  DateTime get _today => widget.today ?? DateTime.now();

  late final Timer _refreshTimer;

  @override
  void initState() {
    super.initState();
    _load();
    _refreshTimer = Timer.periodic(
      noticeRefreshInterval,
      (_) => _refreshNotices(),
    );
  }

  @override
  void dispose() {
    _refreshTimer.cancel();
    super.dispose();
  }

  /// 자동 갱신은 '새 공지'만. 할 일까지 다시 불러오면 방금 체크한 지난 할 일이 목록에서 사라짐.
  Future<void> _refreshNotices() async {
    if (_error != null) return;
    try {
      final notices = await widget.api.fetchNotices(limit: homeNoticeCount);
      if (mounted) setState(() => _notices = notices);
    } on ApiException {
      // 다음 주기에 다시 시도
    }
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final results = await Future.wait<Object>([
        widget.api.fetchMyTasks(),
        widget.api.fetchWeeklyReview(),
        widget.api.fetchNotices(limit: homeNoticeCount),
      ]);
      if (!mounted) return;
      final loaded = results[0] as List<MyTask>;
      setState(() {
        tasks = loaded;
        _todayIds = {for (final t in todayTasks(loaded, _today)) t.id};
        _review = results[1] as WeeklyReview;
        _notices = results[2] as List<NoticeCard>;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  /// 체크가 반영되면 완료율 요약도 다시 받아 옴.
  Future<void> _toggle(MyTask task, bool isDone) async {
    if (!await toggleTask(task, isDone)) return;
    try {
      final review = await widget.api.fetchWeeklyReview();
      if (mounted) setState(() => _review = review);
    } on ApiException {
      // 완료율 요약만 이전 값으로 남음. 다시 불러오면 맞춰짐
    }
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _openTask(MyTask task) async {
    await openSource(context, widget.api, task.source, today: widget.today);
    if (mounted) _load();
  }

  Future<void> _openPreview(NoticeCard notice) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => TaskPreviewScreen(
          api: widget.api,
          noticeId: notice.id,
          link: notice.link,
        ),
      ),
    );
    if (!mounted) return;
    if (saved == true) _showMessage('할 일을 저장했어요');
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final tasks = this.tasks;
    return Scaffold(
      appBar: AppBar(
        title: const Text('홈'),
        actions: [
          if (kIsWeb) // 마우스로는 당겨서 새로고침이 안 됨
            IconButton(
              tooltip: '새로고침',
              onPressed: _load,
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: _error != null
          ? ErrorView(message: _error!, onRetry: _load)
          : tasks == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(onRefresh: _load, child: _buildContent(tasks)),
    );
  }

  Widget _buildContent(List<MyTask> tasks) {
    final today = _today;
    final todayList = sortTodayTasks([
      for (final t in tasks)
        if (_todayIds.contains(t.id)) t,
    ]);
    return ListView(
      padding: EdgeInsets.symmetric(
        horizontal: contentInset(context),
        vertical: 16,
      ),
      children: [
        _deadlineSummary(nearestDeadline(tasks, today), today),
        _todaySummary(tasks, today),
        _reviewSummary(_review!),
        const SectionHeading('오늘 할 일'),
        if (todayList.isEmpty) const Text('오늘 할 일이 없어요'),
        for (final t in todayList)
          MyTaskTile(
            key: ValueKey(t.id),
            task: t,
            today: today,
            pending: pending.contains(t.id),
            onChanged: (v) => _toggle(t, v),
            onTap: () => _openTask(t),
            scheduleLabel: daysLeft(t.scheduledDate!, today) < 0
                ? '지남 · ${monthDay(t.scheduledDate!)}'
                : '오늘',
            scheduleUrgent: daysLeft(t.scheduledDate!, today) < 0,
          ),
        const SectionHeading('새 공지'),
        if (_notices.isEmpty) const Text('새 공지가 없어요'),
        for (final n in _notices)
          NoticeCardView(
            notice: n,
            onDoIt: () => _openPreview(n),
            margin: const EdgeInsets.only(bottom: 12),
          ),
      ],
    );
  }

  Widget _deadlineSummary(MyTask? task, DateTime today) {
    if (task == null) {
      return const _SummaryCard(
        label: '가장 가까운 마감',
        value: '다가오는 마감이 없어요',
        highlight: true,
      );
    }
    final deadline = task.deadline!;
    final time = deadline.time == null
        ? ''
        : ' ${deadline.time!.substring(0, 5)}';
    return _SummaryCard(
      label: '가장 가까운 마감',
      value:
          '${ddayText(daysLeft(deadline.date!, today))} · ${task.source.title}',
      detail: '${deadline.label} ${monthDay(deadline.date!)}$time',
      highlight: true,
    );
  }

  Widget _todaySummary(List<MyTask> tasks, DateTime today) {
    var todayCount = 0, remaining = 0, overdue = 0;
    for (final t in tasks) {
      if (t.scheduledDate == null) continue;
      final days = daysLeft(t.scheduledDate!, today);
      if (days == 0) {
        todayCount++;
        if (!t.isDone) remaining++;
      } else if (days < 0 && !t.isDone) {
        overdue++;
      }
    }
    return _SummaryCard(
      label: '오늘 할 일',
      value: todayCount == 0
          ? '오늘 할 일이 없어요'
          : remaining == 0
          ? '오늘 할 일을 모두 끝냈어요'
          : '$remaining개 남음',
      detail: overdue > 0 ? '지난 할 일 $overdue개' : null,
    );
  }

  Widget _reviewSummary(WeeklyReview review) => _SummaryCard(
    label: '이번 주 완료율',
    value: review.rate == null
        ? '이번 주에 하기로 한 일이 없어요'
        : '${review.planned}개 중 ${review.done}개 완료 · ${(review.rate! * 100).round()}%',
    onTap: () => Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => WeeklyReviewScreen(api: widget.api)),
    ),
  );
}

/// 구역 제목 (홈·캘린더 공용).
class SectionHeading extends StatelessWidget {
  const SectionHeading(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleMedium
            ?.copyWith(fontWeight: FontWeight.bold),
      ),
    );
  }
}

/// 요약 한 칸: 작은 이름표 + 값 (+ 덧붙이는 한 줄). [onTap]이 있으면 누를 수 있음.
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.label,
    required this.value,
    this.detail,
    this.onTap,
    this.highlight = false,
  });

  final String label;
  final String value;
  final String? detail;
  final VoidCallback? onTap;
  final bool highlight; // 화면에서 가장 중요한 요약: 진한 남색 카드

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = highlight
        ? AppColors.card
        : theme.colorScheme.onSurfaceVariant;
    return Card(
      color: highlight ? AppColors.navy : null,
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: highlight ? AppColors.tan : muted,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      value,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: highlight ? AppColors.card : null,
                      ),
                    ),
                    if (detail != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        detail!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: muted,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (onTap != null) Icon(Icons.chevron_right, color: muted),
            ],
          ),
        ),
      ),
    );
  }
}
