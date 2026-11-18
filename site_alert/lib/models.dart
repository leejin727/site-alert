// 서버(serve/main.py) 응답을 담는 클래스.

/// 일정 종류의 표시 이름. 공지에서 담은 것은 '공지'.
String kindLabel(String kind) => switch (kind) {
  'exam' => '시험',
  'contest' => '공모전',
  _ => '공지',
};

/// 할 일·마감이 어디서 왔는지: 공지 또는 직접 만든 일정(시험·공모전).
class TaskSource {
  TaskSource({
    required this.kind,
    required this.title,
    this.noticeId,
    this.noticeLink,
    this.scheduleId,
  });

  final String kind; // notice | exam | contest
  final String title;
  final int? noticeId;
  final String? noticeLink;
  final int? scheduleId;

  bool get isSchedule => scheduleId != null;

  /// 카드의 출처 줄: 공지는 제목 그대로, 일정은 '시험 · 제목'
  String get text => isSchedule ? '${kindLabel(kind)} · $title' : title;

  /// 서버가 주는 `notice` / `schedule` 중 하나에서.
  factory TaskSource.fromJson(Map<String, dynamic> json) {
    final schedule = json['schedule'] as Map<String, dynamic>?;
    if (schedule != null) {
      return TaskSource(
        kind: schedule['kind'] as String,
        title: schedule['title'] as String,
        scheduleId: schedule['id'] as int,
      );
    }
    final notice = json['notice'] as Map<String, dynamic>;
    return TaskSource(
      kind: 'notice',
      title: notice['title'] as String,
      noticeId: notice['id'] as int,
      noticeLink: notice['link'] as String,
    );
  }
}

class DeadlineInfo {
  DeadlineInfo({
    this.id,
    required this.label,
    this.date,
    this.time,
    this.yearCorrected = false,
    this.confidence = '높음',
    this.evidence,
  });

  final int? id; // 직접 만든 일정의 날짜(시험일·마감일)는 id가 없음
  final String label;
  final String? date; // 'YYYY-MM-DD', 날짜를 특정할 수 없으면 null
  final String? time; // 'HH:MM:SS'
  final bool yearCorrected;
  final String confidence;
  final String? evidence;

  factory DeadlineInfo.fromJson(Map<String, dynamic> json) => DeadlineInfo(
    id: json['id'] as int?,
    label: json['label'] as String,
    date: json['deadline_date'] as String?,
    time: json['deadline_time'] as String?,
    yearCorrected: json['year_corrected'] as bool? ?? false,
    confidence: json['confidence'] as String? ?? '높음',
    evidence: json['evidence'] as String?,
  );

  /// 화면 표시용: '2026-10-16 18:00' 또는 '날짜 미정'
  String get when =>
      [date ?? '날짜 미정', if (time != null) time!.substring(0, 5)].join(' ');
}

class NoticeCard {
  NoticeCard({
    required this.id,
    required this.title,
    required this.link,
    required this.board,
    required this.published,
    required this.analyzed,
    required this.saved,
    this.summary,
    this.applyMethod,
    this.nextDeadline,
  });

  final int id;
  final String title;
  final String link; // 공지 원문 주소
  final String board;
  final String published;
  final bool analyzed;
  final bool saved; // 이미 '이거 할래'로 담은 공지
  final String? summary;
  final String? applyMethod;
  final DeadlineInfo? nextDeadline; // 오늘 이후 가장 가까운 마감

  factory NoticeCard.fromJson(Map<String, dynamic> json) => NoticeCard(
    id: json['id'] as int,
    title: json['title'] as String,
    link: json['link'] as String,
    board: json['board'] as String,
    published: json['published'] as String? ?? '',
    analyzed: json['analyzed'] as bool,
    saved: json['saved'] as bool,
    summary: json['summary'] as String?,
    applyMethod: json['apply_method'] as String?,
    nextDeadline: json['next_deadline'] == null
        ? null
        : DeadlineInfo.fromJson(json['next_deadline'] as Map<String, dynamic>),
  );
}

/// 저장된 내 할 일 하나 (서버의 tasks 행).
class TaskItem {
  TaskItem({
    required this.id,
    required this.title,
    this.note,
    this.evidence,
    this.deadlineId,
    this.source = 'ai',
    this.isDone = false,
  });

  final int id;
  final String title;
  final String? note;
  final String? evidence; // AI가 뽑은 할 일의 원문 근거. 직접 추가한 할 일은 null
  final int? deadlineId;
  final String source; // ai | user
  final bool isDone;

  factory TaskItem.fromJson(Map<String, dynamic> json) => TaskItem(
    id: json['id'] as int,
    title: json['title'] as String,
    note: json['note'] as String?,
    evidence: json['evidence'] as String?,
    deadlineId: json['deadline_id'] as int?,
    source: json['source'] as String? ?? 'ai',
    isDone: json['is_done'] as bool? ?? false,
  );
}

class TaskPreview {
  TaskPreview({
    required this.title,
    required this.link,
    required this.deadlines,
    required this.tasks,
    this.unclear = const [],
    this.applyMethod,
    this.applyMethodEvidence,
  });

  final String title;
  final String link; // 공지 원문 주소
  final String? applyMethod;
  final String? applyMethodEvidence;
  final List<DeadlineInfo> deadlines;
  final List<String>
  unclear; // 확인 불가 필드 이름. 예: ['undergrad', 'deadlines[0].date']
  final List<TaskItem> tasks;

  factory TaskPreview.fromJson(Map<String, dynamic> json) {
    final notice = json['notice'] as Map<String, dynamic>;
    return TaskPreview(
      title: notice['title'] as String,
      link: notice['link'] as String,
      applyMethod: json['apply_method'] as String?,
      applyMethodEvidence: json['apply_method_evidence'] as String?,
      deadlines: [
        for (final d in json['deadlines'] as List)
          DeadlineInfo.fromJson(d as Map<String, dynamic>),
      ],
      unclear: [for (final u in json['unclear'] as List? ?? []) u as String],
      tasks: [
        for (final t in json['tasks'] as List)
          TaskItem.fromJson(t as Map<String, dynamic>),
      ],
    );
  }

  /// unclear를 화면에 보여줄 문장으로. 마감은 순번 대신 이름으로 표시.
  List<String> get unclearLabels {
    const names = {
      'target': '대상',
      'undergrad': '학부생 대상 여부',
      'apply_method': '신청 방식',
    };
    return [
      for (final u in unclear)
        if (names[u] != null)
          names[u]!
        else if (RegExp(r'^deadlines\[(\d+)\]').firstMatch(u) case final m?)
          '마감일(${_deadlineLabel(int.parse(m.group(1)!))})'
        else
          u,
    ];
  }

  String _deadlineLabel(int order) =>
      order < deadlines.length ? deadlines[order].label : '${order + 1}번째';
}

/// '내 할 일' 목록의 항목 (GET /tasks). 저장(confirmed)한 할 일만 옴.
class MyTask {
  MyTask({
    required this.id,
    required this.title,
    required this.source,
    this.note,
    this.isDone = false,
    this.deadline,
    this.deadlineFromNotice = false,
    this.scheduledDate,
  });

  final int id;
  final String title;
  final String? note;
  final bool isDone;
  final TaskSource source; // 어느 공지(또는 일정)의 할 일인지
  final DeadlineInfo? deadline;
  final bool deadlineFromNotice; // 할 일에 연결된 마감이 없어 공지의 가장 빠른 마감을 보여줌
  final String? scheduledDate; // 이 할 일을 할 날 (YYYY-MM-DD, 서버가 마감에서 역산해 배정)

  factory MyTask.fromJson(Map<String, dynamic> json) {
    return MyTask(
      id: json['id'] as int,
      title: json['title'] as String,
      note: json['note'] as String?,
      isDone: json['is_done'] as bool? ?? false,
      source: TaskSource.fromJson(json),
      deadline: json['deadline'] == null
          ? null
          : DeadlineInfo.fromJson(json['deadline'] as Map<String, dynamic>),
      deadlineFromNotice: json['deadline_from_notice'] as bool? ?? false,
      scheduledDate: json['scheduled_date'] as String?,
    );
  }

  MyTask copyWith({required bool isDone}) => MyTask(
    id: id,
    title: title,
    note: note,
    isDone: isDone,
    source: source,
    deadline: deadline,
    deadlineFromNotice: deadlineFromNotice,
    scheduledDate: scheduledDate,
  );
}

/// 캘린더에 표시하는 마감: 내가 담은 공지의 날짜 있는 마감과, 직접 만든 일정의 날짜(시험일·마감일).
class MyDeadline {
  MyDeadline({
    this.id,
    required this.label,
    required this.date,
    required this.source,
    this.time,
  });

  final int? id; // 직접 만든 일정의 날짜는 id가 없음
  final String label;
  final String date; // 'YYYY-MM-DD'
  final String? time; // 'HH:MM:SS'
  final TaskSource source;

  factory MyDeadline.fromJson(Map<String, dynamic> json) => MyDeadline(
    id: json['id'] as int?,
    label: json['label'] as String,
    date: json['deadline_date'] as String,
    time: json['deadline_time'] as String?,
    source: TaskSource.fromJson(json),
  );
}

/// 일정 목록의 한 줄: 직접 만든 일정 또는 공지에서 담은 것.
class ScheduleEntry {
  ScheduleEntry({
    required this.source,
    required this.total,
    required this.done,
    this.date,
  });

  final TaskSource source;
  final String? date; // 시험일·마감일. 공지는 가장 가까운 마감 (없으면 null)
  final int total; // 할 일 수
  final int done; // 그중 완료한 수

  factory ScheduleEntry.fromJson(Map<String, dynamic> json) => ScheduleEntry(
    source: TaskSource(
      kind: json['kind'] as String,
      title: json['title'] as String,
      noticeId: json['notice_id'] as int?,
      noticeLink: json['link'] as String?,
      scheduleId: json['schedule_id'] as int?,
    ),
    date: json['date'] as String?,
    total: json['total'] as int,
    done: json['done'] as int,
  );
}

/// 직접 만든 일정의 체크리스트 항목.
class ScheduleTask {
  ScheduleTask({
    required this.id,
    required this.title,
    this.phase,
    this.scheduledDate,
    this.isDone = false,
  });

  final int id;
  final String title;
  final String? phase; // 단계 (준비·공부·직전 / 준비·제작·제출). 없으면 '기타'로 묶음
  final String? scheduledDate; // YYYY-MM-DD
  final bool isDone;

  factory ScheduleTask.fromJson(Map<String, dynamic> json) => ScheduleTask(
    id: json['id'] as int,
    title: json['title'] as String,
    phase: json['phase'] as String?,
    scheduledDate: json['scheduled_date'] as String?,
    isDone: json['is_done'] as bool? ?? false,
  );

  ScheduleTask copyWith({required bool isDone}) => ScheduleTask(
    id: id,
    title: title,
    phase: phase,
    scheduledDate: scheduledDate,
    isDone: isDone,
  );
}

/// 직접 만든 일정(시험·공모전)과 체크리스트.
class ScheduleDetail {
  ScheduleDetail({
    required this.id,
    required this.kind,
    required this.title,
    required this.date,
    required this.phases,
    required this.tasks,
  });

  final int id;
  final String kind; // exam | contest
  final String title;
  final String date; // 시험일 또는 마감일 (YYYY-MM-DD)
  final List<String> phases; // 이 종류의 단계 순서
  final List<ScheduleTask> tasks; // 단계 순서대로

  factory ScheduleDetail.fromJson(Map<String, dynamic> json) => ScheduleDetail(
    id: json['id'] as int,
    kind: json['kind'] as String,
    title: json['title'] as String,
    date: json['target_date'] as String,
    phases: [for (final p in json['phases'] as List) p as String],
    tasks: [
      for (final t in json['tasks'] as List)
        ScheduleTask.fromJson(t as Map<String, dynamic>),
    ],
  );
}

/// 주간 회고의 '끝내지 못한 일' 한 줄.
class ReviewTask {
  ReviewTask({
    required this.id,
    required this.title,
    required this.sourceText,
    this.scheduledDate,
  });

  final int id;
  final String title;
  final String sourceText; // 공지 제목 또는 '시험 · 일정 제목'
  final String? scheduledDate; // 하기로 했던 날 (YYYY-MM-DD)

  factory ReviewTask.fromJson(Map<String, dynamic> json) => ReviewTask(
    id: json['id'] as int,
    title: json['title'] as String,
    sourceText: TaskSource.fromJson(json).text,
    scheduledDate: json['scheduled_date'] as String?,
  );
}

class WeeklyReview {
  WeeklyReview({
    required this.weekStart,
    required this.weekEnd,
    required this.planned,
    required this.done,
    this.rate,
    this.unfinished = const [],
    this.memo,
  });

  final String weekStart; // 그 주의 일요일 (YYYY-MM-DD)
  final String weekEnd; // 토요일
  final int planned; // 그 주에 하기로 한 할 일 수
  final int done; // 그중 완료한 수
  final double? rate; // 계획이 없으면 null
  final List<ReviewTask> unfinished;
  final String? memo;

  factory WeeklyReview.fromJson(Map<String, dynamic> json) => WeeklyReview(
    weekStart: json['week_start'] as String,
    weekEnd: json['week_end'] as String,
    planned: json['planned'] as int,
    done: json['done'] as int,
    rate: (json['rate'] as num?)?.toDouble(),
    unfinished: [
      for (final t in json['unfinished'] as List)
        ReviewTask.fromJson(t as Map<String, dynamic>),
    ],
    memo: json['memo'] as String?,
  );
}
