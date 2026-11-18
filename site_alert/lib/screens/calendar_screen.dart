import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import 'home_screen.dart' show SectionHeading, sortTodayTasks;
import 'my_tasks_screen.dart'
    show MyTaskTile, TaskChecking, daysLeft, ddayText, monthDay;
import 'notice_list_screen.dart' show ErrorView, contentInset;
import 'schedule_detail_screen.dart' show openSource;

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
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  void _moveMonth(int months) {
    setState(() {
      _month = DateTime(_month.year, _month.month + months);
      _selected = _isThisMonth ? isoDate(_today) : null;
    });
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
    final dayTasks = selected == null ? <MyTask>[] : tasksOn(tasks, selected);
    final dayDeadlines = [
      for (final d in _deadlines)
        if (d.date == selected) d,
    ];
    final monthDeadlines = deadlinesIn(_deadlines, _month.year, _month.month);
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
          onTap: (day) => setState(() => _selected = isoDate(day)),
        ),
        const SizedBox(height: 8),
        const _Legend(),
        SectionHeading(
          selected == null ? '날짜별 보기' : _dayTitle(DateTime.parse(selected)),
        ),
        if (selected == null)
          const Text('날짜를 누르면 그날의 할 일과 마감이 보여요')
        else if (dayTasks.isEmpty && dayDeadlines.isEmpty)
          const Text('이 날은 할 일과 마감이 없어요'),
        for (final d in dayDeadlines)
          _DeadlineTile(
            deadline: d,
            today: today,
            onTap: () => _openSource(d.source),
          ),
        for (final t in dayTasks)
          MyTaskTile(
            key: ValueKey(t.id),
            task: t,
            today: today,
            pending: pending.contains(t.id),
            onChanged: (v) => toggleTask(t, v),
            onTap: () => _openSource(t.source),
          ),
        SectionHeading('${_isThisMonth ? '이번 달' : '${_month.month}월'} 마감'),
        if (monthDeadlines.isEmpty) const Text('마감이 없어요'),
        for (final d in monthDeadlines)
          _DeadlineTile(
            deadline: d,
            today: today,
            showDate: true,
            onTap: () => _openSource(d.source),
          ),
      ],
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
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      margin: const EdgeInsets.symmetric(horizontal: 1.5),
      decoration: switch (kind) {
        _MarkKind.todo => BoxDecoration(
          color: scheme.primary,
          shape: BoxShape.circle,
        ),
        _MarkKind.done => BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: scheme.outline, width: 1.2),
        ),
        _MarkKind.deadline => BoxDecoration(color: scheme.error),
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
    final scheme = theme.colorScheme;
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
                  color: selected ? scheme.secondaryContainer : null,
                  border: isToday
                      ? Border.all(color: scheme.primary, width: 1.5)
                      : null,
                ),
                child: ExcludeSemantics(
                  child: Text(
                    '${day.day}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: selected ? scheme.onSecondaryContainer : null,
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

/// 마감 한 줄: 공지 제목, 마감 이름(시각), D-day. [showDate]면 앞에 날짜.
class _DeadlineTile extends StatelessWidget {
  const _DeadlineTile({
    required this.deadline,
    required this.today,
    required this.onTap,
    this.showDate = false,
  });

  final MyDeadline deadline;
  final DateTime today;
  final VoidCallback onTap;
  final bool showDate;

  @override
  Widget build(BuildContext context) {
    final time = deadline.time == null
        ? ''
        : ' ${deadline.time!.substring(0, 5)}';
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: onTap,
        leading: showDate ? Text(monthDay(deadline.date)) : null,
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
