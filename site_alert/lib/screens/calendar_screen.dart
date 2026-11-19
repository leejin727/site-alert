import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import 'home_screen.dart' show SectionHeading, sortTodayTasks;
import 'my_tasks_screen.dart'
    show TaskChecking, daysLeft, ddayText, monthDay, urgentDays;
import 'notice_list_screen.dart' show ErrorView, contentInset;
import 'schedule_detail_screen.dart' show openSource, scheduleDday;
import 'task_preview_screen.dart' show Tag;
import '../theme.dart';

const weekdayLabels = ['일', '월', '화', '수', '목', '금', '토'];

String isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// 그 달의 달력 칸 (일요일 시작). 1일 앞과 말일 뒤의 빈칸은 null이고 길이는 7의 배수.
List<DateTime?> monthCells(int year, int month) {
  final lead = DateTime(year, month).weekday % 7;
  final days = DateTime(year, month + 1, 0).day;
  final cells = <DateTime?>[
    for (var i = 0; i < lead; i++) null,
    for (var d = 1; d <= days; d++) DateTime(year, month, d),
  ];
  while (cells.length % 7 != 0) {
    cells.add(null);
  }
  return cells;
}

/// 날짜 칸의 표시: 미완료 할 일의 예정일 / 완료한 할 일의 예정일 / 마감일.
typedef DayMarks = ({bool todo, bool done, bool deadline});

Map<String, DayMarks> calendarMarks(
  List<MyTask> tasks,
  List<MyDeadline> deadlines,
) {
  final marks = <String, DayMarks>{};
  DayMarks at(String date) =>
      marks[date] ?? (todo: false, done: false, deadline: false);
  for (final t in tasks) {
    final date = t.scheduledDate;
    if (date == null) continue;
    final m = at(date);
    marks[date] = (
      todo: m.todo || !t.isDone,
      done: m.done || t.isDone,
      deadline: m.deadline,
    );
  }
  for (final d in deadlines) {
    final m = at(d.date);
    marks[d.date] = (todo: m.todo, done: m.done, deadline: true);
  }
  return marks;
}

/// 그날 하기로 한 할 일. 미완료가 위.
List<MyTask> tasksOn(List<MyTask> tasks, String date) => sortTodayTasks([
  for (final t in tasks)
    if (t.scheduledDate == date) t,
]);

/// 그날 카드의 상태 배지. 할 일 없이 마감만 있으면 마감 수, 둘 다 없으면 null.
String? dayStatus(List<MyTask> tasks, int deadlines) {
  if (tasks.isEmpty) return deadlines == 0 ? null : '마감 $deadlines개';
  final done = tasks.where((t) => t.isDone).length;
  return done == tasks.length ? '모두 완료' : '${tasks.length}개 중 $done개 완료';
}

/// 그 달의 마감. 서버가 준 순서(빠른 순) 그대로.
List<MyDeadline> deadlinesIn(List<MyDeadline> deadlines, int year, int month) {
  final prefix = isoDate(DateTime(year, month)).substring(0, 8); // 'YYYY-MM-'
  return [
    for (final d in deadlines)
      if (d.date.startsWith(prefix)) d,
  ];
}

/// 캘린더: 보기 전용 월간 달력. 할 일 예정일과 마감일을 표시하고, 날짜를 누르면 그날의 목록을 보여 줌.
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key, required this.api, this.today});

  final ApiClient api;
  final DateTime? today; // 테스트용. 없으면 기기의 오늘 날짜

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen>
    with TaskChecking<CalendarScreen> {
  List<MyDeadline> _deadlines = [];
  String? _error;
  late DateTime _month = DateTime(_today.year, _today.month); // 보고 있는 달의 1일
  late String? _selected = isoDate(_today);
  // 선택한 날의 할 일 순서. 체크한 줄이 그 자리에서 그려지도록 불러오거나 날짜를 고를 때만 다시 정함
  List<int> _dayOrder = [];
  bool _intro = true; // 화면이 처음 열릴 때만 이미 끝낸 항목의 체크를 차례로 그림

  @override
  ApiClient get taskApi => widget.api;

  DateTime get _today => widget.today ?? DateTime.now();

  bool get _isThisMonth =>
      _month.year == _today.year && _month.month == _today.month;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final results = await Future.wait<Object>([
        widget.api.fetchMyTasks(),
        widget.api.fetchMyDeadlines(),
      ]);
      if (!mounted) return;
      setState(() {
        tasks = results[0] as List<MyTask>;
        _deadlines = results[1] as List<MyDeadline>;
        _sortDay();
      });
      WidgetsBinding.instance.addPostFrameCallback((_) => _intro = false);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  void _sortDay() {
    final selected = _selected;
    _dayOrder = [
      if (selected != null)
        for (final t in tasksOn(tasks ?? [], selected)) t.id,
    ];
  }

  void _select(String? date) {
    setState(() {
      _selected = date;
      _sortDay();
    });
  }

  void _moveMonth(int months) {
    _month = DateTime(_month.year, _month.month + months);
    _select(_isThisMonth ? isoDate(_today) : null);
  }

  Future<void> _openSource(TaskSource source) async {
    await openSource(context, widget.api, source, today: widget.today);
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final tasks = this.tasks;
    return Scaffold(
      appBar: AppBar(
        title: const Text('캘린더'),
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
    final marks = calendarMarks(tasks, _deadlines);
    final selected = _selected;
    final byId = {for (final t in tasks) t.id: t};
    final dayTasks = [for (final id in _dayOrder) ?byId[id]];
    final dayDeadlines = [
      for (final d in _deadlines)
        if (d.date == selected) d,
    ];
    final monthDeadlines = deadlinesIn(_deadlines, _month.year, _month.month);
    final rowCount = dayDeadlines.length + dayTasks.length;
    var introIndex = 0;
    return ListView(
      padding: EdgeInsets.symmetric(
        horizontal: contentInset(context),
        vertical: 16,
      ),
      children: [
        MonthHeader(month: _month, onMove: _moveMonth),
        const SizedBox(height: 8),
        MonthGrid(
          month: _month,
          today: today,
          selected: selected,
          marks: marks,
          onTap: (day) => _select(isoDate(day)),
        ),
        const SizedBox(height: 8),
        const _Legend(),
        const SizedBox(height: 16),
        _DayCard(
          title: selected == null
              ? '날짜별 보기'
              : _dayTitle(DateTime.parse(selected)),
          status: dayStatus(dayTasks, dayDeadlines.length),
          emptyText: selected == null
              ? '날짜를 누르면 그날의 할 일과 마감이 보여요'
              : '이 날은 할 일과 마감이 없어요',
          rows: [
            for (final (i, d) in dayDeadlines.indexed)
              _TimelineRow(
                marker: const _DeadlineMarker(),
                title: d.label,
                badge: _deadlineBadge(d, today),
                warning: true,
                source: d.source.text,
                onOpen: () => _openSource(d.source),
                first: i == 0,
                last: i == rowCount - 1,
              ),
            for (final (i, t) in dayTasks.indexed)
              _taskRow(
                t,
                today,
                first: dayDeadlines.isEmpty && i == 0,
                last: dayDeadlines.length + i == rowCount - 1,
                introDelay: _intro && t.isDone
                    ? _CheckCircle.introStep * introIndex++
                    : null,
              ),
          ],
        ),
        SectionHeading('${_isThisMonth ? '이번 달' : '${_month.month}월'} 마감'),
        if (monthDeadlines.isEmpty) const Text('마감이 없어요'),
        for (final d in monthDeadlines)
          _DeadlineTile(
            deadline: d,
            today: today,
            onTap: () => _openSource(d.source),
          ),
      ],
    );
  }

  /// 직접 만든 일정의 날짜(시험일·마감일)는 이름이 이미 뜻을 말하므로 남은 날을, 공지 마감은 '마감'과 시각을.
  String _deadlineBadge(MyDeadline deadline, DateTime today) {
    if (deadline.source.isSchedule) {
      return scheduleDday(daysLeft(deadline.date, today));
    }
    final time = deadline.time;
    return time == null ? '마감' : '마감 ${time.substring(0, 5)}';
  }

  Widget _taskRow(
    MyTask task,
    DateTime today, {
    required bool first,
    required bool last,
    required Duration? introDelay,
  }) {
    final date = task.deadline?.date;
    final days = date == null ? null : daysLeft(date, today);
    return _TimelineRow(
      key: ValueKey(task.id),
      marker: _CheckCircle(
        key: ValueKey('check-${task.id}'),
        checked: task.isDone,
        label: task.title,
        introDelay: introDelay,
        onChanged: pending.contains(task.id)
            ? null
            : (v) => toggleTask(task, v),
      ),
      title: task.title,
      badge: task.isDone || days == null ? null : ddayText(days),
      warning: days != null && days >= 0 && days <= urgentDays,
      dimmed: task.isDone || (days != null && days < 0),
      source: task.source.text,
      onOpen: () => _openSource(task.source),
      first: first,
      last: last,
    );
  }

  String _dayTitle(DateTime day) =>
      '${day.month}월 ${day.day}일 (${weekdayLabels[day.weekday % 7]})';
}

/// 달 이동 머리: '‹ 2026년 11월 ›'. [onMove]에 -1(이전 달) 또는 1(다음 달).
class MonthHeader extends StatelessWidget {
  const MonthHeader({super.key, required this.month, required this.onMove});

  final DateTime month;
  final ValueChanged<int> onMove;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          tooltip: '이전 달',
          onPressed: () => onMove(-1),
          icon: const Icon(Icons.chevron_left),
        ),
        Expanded(
          child: Text(
            '${month.year}년 ${month.month}월',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        IconButton(
          tooltip: '다음 달',
          onPressed: () => onMove(1),
          icon: const Icon(Icons.chevron_right),
        ),
      ],
    );
  }
}

/// 월간 달력 격자 (요일 줄 + 날짜 칸). 캘린더 화면과 날짜 선택 창이 함께 씀.
class MonthGrid extends StatelessWidget {
  const MonthGrid({
    super.key,
    required this.month,
    required this.today,
    required this.onTap,
    this.selected,
    this.marks = const {},
    this.keyPrefix = 'day',
  });

  final DateTime month; // 보여줄 달의 아무 날짜
  final DateTime today;
  final String? selected; // 선택된 날짜 (YYYY-MM-DD)
  final Map<String, DayMarks> marks;
  final ValueChanged<DateTime> onTap;
  final String keyPrefix; // 날짜 칸의 key: '<keyPrefix>-YYYY-MM-DD'

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final todayIso = isoDate(today);
    final cells = monthCells(month.year, month.month);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            for (final label in weekdayLabels)
              Expanded(
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        for (var i = 0; i < cells.length; i += 7)
          Row(
            children: [
              for (final day in cells.sublist(i, i + 7))
                Expanded(
                  child: day == null
                      ? const SizedBox(height: _DayCell.height)
                      : _DayCell(
                          key: ValueKey('$keyPrefix-${isoDate(day)}'),
                          day: day,
                          marks: marks[isoDate(day)],
                          isToday: isoDate(day) == todayIso,
                          selected: isoDate(day) == selected,
                          onTap: () => onTap(day),
                        ),
                ),
            ],
          ),
      ],
    );
  }
}

/// 날짜 선택 창 (캘린더와 같은 달력). 날짜를 누르면 그 날짜, 닫으면 null.
Future<DateTime?> pickDate(
  BuildContext context, {
  DateTime? initial,
  DateTime? today,
}) => showDialog<DateTime>(
  context: context,
  builder: (_) =>
      _DatePickerDialog(initial: initial, today: today ?? DateTime.now()),
);

class _DatePickerDialog extends StatefulWidget {
  const _DatePickerDialog({required this.initial, required this.today});

  final DateTime? initial;
  final DateTime today;

  @override
  State<_DatePickerDialog> createState() => _DatePickerDialogState();
}

class _DatePickerDialogState extends State<_DatePickerDialog> {
  late DateTime _month = DateTime(
    (widget.initial ?? widget.today).year,
    (widget.initial ?? widget.today).month,
  );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('날짜 선택'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MonthHeader(
              month: _month,
              onMove: (months) => setState(
                () => _month = DateTime(_month.year, _month.month + months),
              ),
            ),
            const SizedBox(height: 8),
            MonthGrid(
              month: _month,
              today: widget.today,
              selected: widget.initial == null
                  ? null
                  : isoDate(widget.initial!),
              keyPrefix: 'pick',
              onTap: (day) => Navigator.pop(context, day),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('취소'),
        ),
      ],
    );
  }
}

enum _MarkKind { todo, done, deadline }

/// 날짜 칸의 작은 표시. 미완료 할 일 = 채운 원, 완료한 할 일 = 빈 원, 마감 = 사각형.
class _Mark extends StatelessWidget {
  const _Mark(this.kind, {super.key});

  final _MarkKind kind;

  static const size = 6.0;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      margin: const EdgeInsets.symmetric(horizontal: 1.5),
      decoration: switch (kind) {
        _MarkKind.todo => const BoxDecoration(
          color: AppColors.navy,
          shape: BoxShape.circle,
        ),
        _MarkKind.done => BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.mutedNavy, width: 1.2),
        ),
        _MarkKind.deadline => const BoxDecoration(color: AppColors.brown),
      },
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        for (final (kind, label) in const [
          (_MarkKind.todo, '할 일'),
          (_MarkKind.done, '완료'),
          (_MarkKind.deadline, '마감'),
        ]) ...[
          _Mark(kind),
          const SizedBox(width: 4),
          Text(label, style: style),
          const SizedBox(width: 12),
        ],
      ],
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    super.key,
    required this.day,
    required this.marks,
    required this.isToday,
    required this.selected,
    required this.onTap,
  });

  final DateTime day;
  final DayMarks? marks;
  final bool isToday;
  final bool selected;
  final VoidCallback onTap;

  static const height = 52.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iso = isoDate(day);
    final m = marks;
    return Semantics(
      button: true,
      selected: selected,
      label: [
        '${day.month}월 ${day.day}일',
        if (isToday) '오늘',
        if (m != null && m.todo) '할 일',
        if (m != null && m.done) '완료한 할 일',
        if (m != null && m.deadline) '마감',
      ].join(', '),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: height,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected ? AppColors.navy : null,
                  border: isToday
                      ? Border.all(color: AppColors.navy, width: 1.5)
                      : null,
                ),
                child: ExcludeSemantics(
                  child: Text(
                    '${day.day}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: selected ? AppColors.card : null,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              SizedBox(
                height: _Mark.size,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (m != null && m.todo)
                      _Mark(_MarkKind.todo, key: ValueKey('todo-$iso')),
                    if (m != null && m.done)
                      _Mark(_MarkKind.done, key: ValueKey('done-$iso')),
                    if (m != null && m.deadline)
                      _Mark(_MarkKind.deadline, key: ValueKey('deadline-$iso')),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 그 달의 마감 한 줄: 날짜, 공지 제목, 마감 이름(시각), D-day.
class _DeadlineTile extends StatelessWidget {
  const _DeadlineTile({
    required this.deadline,
    required this.today,
    required this.onTap,
  });

  final MyDeadline deadline;
  final DateTime today;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final time = deadline.time == null
        ? ''
        : ' ${deadline.time!.substring(0, 5)}';
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: onTap,
        leading: Text(monthDay(deadline.date)),
        title: Text(
          deadline.source.text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text('${deadline.label}$time'),
        trailing: Text(ddayText(daysLeft(deadline.date, today))),
      ),
    );
  }
}

/// 선택한 날의 카드: 위에 날짜와 상태 배지, 아래에 그날의 마감과 할 일을 세로 타임라인으로.
class _DayCard extends StatelessWidget {
  const _DayCard({
    required this.title,
    required this.status,
    required this.emptyText,
    required this.rows,
  });

  final String title;
  final String? status;
  final String emptyText;
  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (status != null) Tag(status!),
                ],
              ),
            ),
            const SizedBox(height: 8),
            if (rows.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(emptyText),
              ),
            // 표시(폭 24)의 왼쪽 끝이 위의 날짜와 맞도록 누르는 영역만큼 당김
            Padding(
              padding: const EdgeInsets.only(
                left: 16 - (_TimelineRow.gutter - _TimelineRow.markerSize) / 2,
                right: 16,
              ),
              child: Column(children: rows),
            ),
          ],
        ),
      ),
    );
  }
}

/// 타임라인 한 줄: 왼쪽에 표시(체크 원·마감 네모)와 위아래 줄을 잇는 세로선, 오른쪽에 제목·배지와 출처 칸.
class _TimelineRow extends StatelessWidget {
  const _TimelineRow({
    super.key,
    required this.marker,
    required this.title,
    required this.source,
    required this.onOpen,
    required this.first,
    required this.last,
    this.badge,
    this.warning = false,
    this.dimmed = false,
  });

  final Widget marker;
  final String title;
  final String? badge;
  final bool warning; // 배지를 주의를 끄는 색으로
  final bool dimmed; // 끝냈거나 마감이 지난 할 일: 흐리게, 취소선
  final String source;
  final VoidCallback onOpen;
  final bool first;
  final bool last;

  static const gutter = 44.0; // 표시를 누르는 영역
  static const markerSize = 24.0;
  static const _lineWidth = 1.5;
  static const _lineGap = 4.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final line = ColoredBox(color: theme.colorScheme.outlineVariant);
    const markerTop = (gutter - markerSize) / 2;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: gutter,
            child: Stack(
              children: [
                if (!first)
                  Positioned(
                    left: (gutter - _lineWidth) / 2,
                    width: _lineWidth,
                    top: 0,
                    height: markerTop - _lineGap,
                    child: line,
                  ),
                if (!last)
                  Positioned(
                    left: (gutter - _lineWidth) / 2,
                    width: _lineWidth,
                    top: markerTop + markerSize + _lineGap,
                    bottom: 0,
                    child: line,
                  ),
                Positioned(
                  left: 0,
                  top: 0,
                  width: gutter,
                  height: gutter,
                  child: Center(child: marker),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? 0 : 8),
              child: InkWell(
                onTap: onOpen,
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  // 제목 첫 줄의 가운데가 표시의 가운데에 오도록
                  padding: const EdgeInsets.fromLTRB(2, 12, 0, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Flexible(
                            child: Text(
                              title,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                                decoration: dimmed
                                    ? TextDecoration.lineThrough
                                    : null,
                                color: dimmed ? muted : null,
                              ),
                            ),
                          ),
                          if (badge != null) ...[
                            const SizedBox(width: 8),
                            Tag(badge!, warning: warning),
                          ],
                        ],
                      ),
                      const SizedBox(height: 8),
                      Ink(
                        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                        decoration: BoxDecoration(
                          color: AppColors.background,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                source,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                            Icon(Icons.chevron_right, size: 18, color: muted),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 마감 줄의 표시. 달력 칸의 마감 표시와 같은 네모.
class _DeadlineMarker extends StatelessWidget {
  const _DeadlineMarker();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: AppColors.brown,
        borderRadius: BorderRadius.circular(3),
      ),
    );
  }
}

/// 할 일 줄의 체크 원. 끝내지 않았으면 테두리만, 끝내면 원이 채워지면서 체크가 그려짐.
class _CheckCircle extends StatefulWidget {
  const _CheckCircle({
    super.key,
    required this.checked,
    required this.label,
    required this.onChanged,
    this.introDelay,
  });

  final bool checked;
  final String label; // 화면 읽기용: 할 일 제목
  final ValueChanged<bool>? onChanged; // null이면 누를 수 없음 (서버에 반영 중)
  final Duration? introDelay; // 화면이 처음 열릴 때 이미 끝낸 항목: 이만큼 기다렸다가 체크를 그림

  static const duration = Duration(milliseconds: 300);
  static const introStep = Duration(milliseconds: 120);

  @override
  State<_CheckCircle> createState() => _CheckCircleState();
}

class _CheckCircleState extends State<_CheckCircle>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _CheckCircle.duration,
  );
  Curve _curve = Curves.linear;

  double get _progress => _curve.transform(_controller.value);

  @override
  void initState() {
    super.initState();
    final delay = widget.introDelay;
    if (!widget.checked) return;
    if (delay == null) {
      _controller.value = 1;
      return;
    }
    // 기다리는 시간까지 한 애니메이션에 넣음 (타이머를 따로 두지 않음)
    final total = delay + _CheckCircle.duration;
    _controller.duration = total;
    _curve = Interval(delay.inMilliseconds / total.inMilliseconds, 1);
    _controller.forward();
  }

  @override
  void didUpdateWidget(_CheckCircle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.checked == widget.checked) return;
    final current = _progress;
    _curve = Curves.linear;
    _controller
      ..duration = _CheckCircle.duration
      ..value = current;
    if (widget.checked) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onChanged = widget.onChanged;
    final still = MediaQuery.disableAnimationsOf(context);
    return Semantics(
      checked: widget.checked,
      label: widget.label,
      child: InkResponse(
        onTap: onChanged == null ? null : () => onChanged(!widget.checked),
        radius: _TimelineRow.gutter / 2,
        child: SizedBox.square(
          dimension: _TimelineRow.gutter,
          child: Center(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) => CustomPaint(
                size: const Size.square(_TimelineRow.markerSize),
                painter: _CheckPainter(
                  still ? (widget.checked ? 1 : 0) : _progress,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CheckPainter extends CustomPainter {
  const _CheckPainter(this.progress);

  final double progress; // 0 = 빈 원, 1 = 채운 원과 체크

  static const _fill = Interval(0, 0.6, curve: Curves.easeOut);
  static const _stroke = Interval(0.3, 1, curve: Curves.easeOut);

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2;
    canvas.drawCircle(
      center,
      radius - 0.75,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = AppColors.mutedNavy,
    );
    if (progress <= 0) return;
    canvas.drawCircle(
      center,
      radius * _fill.transform(progress),
      Paint()..color = AppColors.navy,
    );
    final unit = size.width / 24;
    final check = Path()
      ..moveTo(7 * unit, 12.5 * unit)
      ..lineTo(10.5 * unit, 16 * unit)
      ..lineTo(17 * unit, 8.5 * unit);
    final metric = check.computeMetrics().first;
    canvas.drawPath(
      metric.extractPath(0, metric.length * _stroke.transform(progress)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 * unit
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = AppColors.card,
    );
  }

  @override
  bool shouldRepaint(_CheckPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
