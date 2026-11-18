import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'models.dart';

class ApiException implements Exception {
  ApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ApiClient {
  ApiClient({http.Client? client, String? baseUrl})
    : _client = client ?? http.Client(),
      baseUrl = baseUrl ?? defaultBaseUrl();

  /// --dart-define=API_BASE_URL이 있으면 그 값(실제 기기: `http://<Mac IP>:8000`).
  /// 없으면 웹 릴리스 빌드(`flutter build web`)는 화면을 내려준 서버의 주소 그대로,
  /// 안드로이드 에뮬레이터는 10.0.2.2(에뮬레이터에서 본 Mac의 localhost), 그 외(iOS 시뮬레이터·`flutter run -d chrome`·데스크톱)는 127.0.0.1.
  static String defaultBaseUrl({TargetPlatform? platform}) {
    const fromDefine = String.fromEnvironment('API_BASE_URL');
    if (fromDefine.isNotEmpty) return fromDefine;
    if (kIsWeb && kReleaseMode) return Uri.base.origin;
    final isAndroid =
        !kIsWeb &&
        (platform ?? defaultTargetPlatform) == TargetPlatform.android;
    return isAndroid ? 'http://10.0.2.2:8000' : 'http://127.0.0.1:8000';
  }

  final http.Client _client;
  final String baseUrl;

  static const _timeout = Duration(seconds: 15);
  // 처음 분해하는 공지는 Gemini를 기다림 (서버의 재시도 포함)
  static const _previewTimeout = Duration(seconds: 90);

  /// [limit]을 주면 앞에서부터 그 개수만. 기본은 최신순, [byDeadline]이면 마감이 가까운 순.
  Future<List<NoticeCard>> fetchNotices({
    int? limit,
    bool byDeadline = false,
  }) async {
    final params = [
      if (limit != null) 'limit=$limit',
      if (byDeadline) 'sort=deadline',
    ];
    final query = params.isEmpty ? '' : '?${params.join('&')}';
    final data = await _send(
      _client.get(Uri.parse('$baseUrl/notices$query')),
      _timeout,
    ) as List;
    return [
      for (final n in data) NoticeCard.fromJson(n as Map<String, dynamic>),
    ];
  }

  /// '이거 할래' 미리보기: 할 일을 draft로 만들고(이미 있으면 그대로) 미리보기 내용을 받음.
  Future<TaskPreview> startTasks(int noticeId) async {
    final data = await _send(
      _client.post(Uri.parse('$baseUrl/notices/$noticeId/tasks')),
      _previewTimeout,
    );
    return TaskPreview.fromJson(data as Map<String, dynamic>);
  }

  Future<TaskItem> updateTask(
    int taskId, {
    required String title,
    String? note,
  }) async {
    final data = await _send(
      _client.patch(
        Uri.parse('$baseUrl/tasks/$taskId'),
        headers: _json,
        body: jsonEncode({'title': title, 'note': note}),
      ),
      _timeout,
    );
    return TaskItem.fromJson(data as Map<String, dynamic>);
  }

  Future<TaskItem> addTask(
    int noticeId, {
    required String title,
    String? note,
  }) async {
    final data = await _send(
      _client.post(
        Uri.parse('$baseUrl/notices/$noticeId/tasks/items'),
        headers: _json,
        body: jsonEncode({'title': title, 'note': note}),
      ),
      _timeout,
    );
    return TaskItem.fromJson(data as Map<String, dynamic>);
  }

  /// 미리보기의 '저장': 이 공지의 draft 할 일을 모두 confirmed로.
  Future<void> confirmTasks(int noticeId) async {
    await _send(
      _client.post(Uri.parse('$baseUrl/notices/$noticeId/tasks/confirm')),
      _timeout,
    );
  }

  /// '내 할 일': 저장한 할 일(완료 포함)을 마감이 가까운 순으로.
  Future<List<MyTask>> fetchMyTasks() async {
    final data =
        await _send(_client.get(Uri.parse('$baseUrl/tasks')), _timeout) as List;
    return [for (final t in data) MyTask.fromJson(t as Map<String, dynamic>)];
  }

  /// 캘린더: 내가 담은 공지의 날짜 있는 마감 (빠른 순).
  Future<List<MyDeadline>> fetchMyDeadlines() async {
    final data = await _send(
      _client.get(Uri.parse('$baseUrl/deadlines')),
      _timeout,
    ) as List;
    return [
      for (final d in data) MyDeadline.fromJson(d as Map<String, dynamic>),
    ];
  }

  Future<void> setDone(int taskId, bool isDone) async {
    await _send(
      _client.patch(
        Uri.parse('$baseUrl/tasks/$taskId'),
        headers: _json,
        body: jsonEncode({'is_done': isDone}),
      ),
      _timeout,
    );
  }

  /// 주간 회고: week(그 주의 아무 날짜, YYYY-MM-DD)가 속한 주(일~토). 없으면 이번 주.
  Future<WeeklyReview> fetchWeeklyReview({String? week}) async {
    final data = await _send(
      _client.get(
        Uri.parse('$baseUrl/reviews/weekly')
            .replace(queryParameters: week == null ? null : {'week': week}),
      ),
      _timeout,
    );
    return WeeklyReview.fromJson(data as Map<String, dynamic>);
  }

  /// 회고 메모 저장 (그 주에 이미 있으면 덮어씀). 저장된 회고 전체를 돌려받음.
  Future<WeeklyReview> saveWeeklyReview(String week, String memo) async {
    final data = await _send(
      _client.put(
        Uri.parse('$baseUrl/reviews/weekly')
            .replace(queryParameters: {'week': week}),
        headers: _json,
        body: jsonEncode({'memo': memo}),
      ),
      _timeout,
    );
    return WeeklyReview.fromJson(data as Map<String, dynamic>);
  }

  /// 일정 목록: 직접 만든 일정과 공지에서 담은 것 (서버가 정렬).
  Future<List<ScheduleEntry>> fetchSchedules() async {
    final data = await _send(
      _client.get(Uri.parse('$baseUrl/schedules')),
      _timeout,
    ) as List;
    return [
      for (final e in data) ScheduleEntry.fromJson(e as Map<String, dynamic>),
    ];
  }

  Future<ScheduleDetail> fetchSchedule(int scheduleId) async {
    final data = await _send(
      _client.get(Uri.parse('$baseUrl/schedules/$scheduleId')),
      _timeout,
    );
    return ScheduleDetail.fromJson(data as Map<String, dynamic>);
  }

  /// 일정 등록. [useChecklist]면 서버가 기본 체크리스트를 날짜에 맞춰 넣음.
  Future<ScheduleDetail> createSchedule({
    required String kind,
    required String title,
    required String date,
    required bool useChecklist,
  }) async {
    final data = await _send(
      _client.post(
        Uri.parse('$baseUrl/schedules'),
        headers: _json,
        body: jsonEncode({
          'kind': kind,
          'title': title,
          'target_date': date,
          'use_checklist': useChecklist,
        }),
      ),
      _timeout,
    );
    return ScheduleDetail.fromJson(data as Map<String, dynamic>);
  }

  /// 일정의 제목·날짜 수정. 날짜가 바뀌면 서버가 완료하지 않은 기본 항목의 예정일을 다시 계산.
  Future<ScheduleDetail> updateSchedule(
    int scheduleId, {
    required String title,
    required String date,
  }) async {
    final data = await _send(
      _client.patch(
        Uri.parse('$baseUrl/schedules/$scheduleId'),
        headers: _json,
        body: jsonEncode({'title': title, 'target_date': date}),
      ),
      _timeout,
    );
    return ScheduleDetail.fromJson(data as Map<String, dynamic>);
  }

  Future<void> deleteSchedule(int scheduleId) async {
    await _send(
      _client.delete(Uri.parse('$baseUrl/schedules/$scheduleId')),
      _timeout,
    );
  }

  Future<ScheduleTask> addScheduleTask(
    int scheduleId, {
    required String title,
    String? phase,
    String? scheduledDate,
  }) async {
    final data = await _send(
      _client.post(
        Uri.parse('$baseUrl/schedules/$scheduleId/tasks'),
        headers: _json,
        body: jsonEncode({
          'title': title,
          'phase': phase,
          'scheduled_date': scheduledDate,
        }),
      ),
      _timeout,
    );
    return ScheduleTask.fromJson(data as Map<String, dynamic>);
  }

  /// 체크리스트 항목의 제목·예정일 수정 ([scheduledDate]가 null이면 예정일을 비움).
  Future<ScheduleTask> updateScheduleTask(
    int taskId, {
    required String title,
    required String? scheduledDate,
  }) async {
    final data = await _send(
      _client.patch(
        Uri.parse('$baseUrl/tasks/$taskId'),
        headers: _json,
        body: jsonEncode({'title': title, 'scheduled_date': scheduledDate}),
      ),
      _timeout,
    );
    return ScheduleTask.fromJson(data as Map<String, dynamic>);
  }

  Future<void> deleteTask(int taskId) async {
    await _send(_client.delete(Uri.parse('$baseUrl/tasks/$taskId')), _timeout);
  }

  static const _json = {'Content-Type': 'application/json'};

  Future<dynamic> _send(Future<http.Response> request, Duration timeout) async {
    final http.Response resp;
    try {
      resp = await request.timeout(timeout);
    } on TimeoutException {
      throw ApiException('서버 응답이 너무 늦습니다. 잠시 후 다시 시도해 주세요');
    } on http.ClientException {
      throw ApiException('서버에 연결할 수 없습니다 ($baseUrl)');
    }
    final body = utf8.decode(resp.bodyBytes); // 한글이 깨지지 않도록 바이트에서 직접 디코딩
    final data = body.isEmpty ? null : jsonDecode(body);
    if (resp.statusCode >= 400) {
      final detail = data is Map ? data['detail'] : null;
      throw ApiException(
        detail is String ? detail : '요청에 실패했습니다 (${resp.statusCode})',
      );
    }
    return data;
  }
}
