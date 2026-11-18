import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:site_alert/api.dart';
import 'package:site_alert/main.dart';
import 'package:site_alert/models.dart';
import 'package:site_alert/screens/calendar_screen.dart';
import 'package:site_alert/screens/home_screen.dart';
import 'package:site_alert/screens/my_tasks_screen.dart';
import 'package:site_alert/screens/notice_list_screen.dart' show InfoChip;
import 'package:site_alert/screens/task_preview_screen.dart' show Tag;

final notices = [
  {
    'id': 1,
    'title': '학점포기 신청 안내',
    'link': 'https://www.mju.ac.kr/bbs/mjukr/143/236065/artclView.do',
    'board': '학사공지',
    'published': '2026.10.06',
    'analyzed': true,
    'saved': false,
    'summary': '학점포기 신청 기간 안내',
    'apply_method': '기간 내 제출',
    'next_deadline': {
      'id': 10,
      'label': '신청',
      'deadline_date': '2026-10-16',
      'deadline_time': '18:00:00',
    },
  },
  {
    'id': 2,
    'title': '분석 전 공지',
    'link': 'https://www.mju.ac.kr/bbs/mjukr/141/1/artclView.do',
    'board': '일반공지',
    'published': '2026-10-07 09:00:00.0',
    'analyzed': false,
    'saved': false,
    'summary': null,
    'apply_method': null,
    'next_deadline': null,
  },
];

Map<String, dynamic> task(
  int id,
  String title, {
  String? evidence,
  String source = 'ai',
  String? note,
}) => {
  'id': id,
  'title': title,
  'note': note,
  'evidence': evidence,
  'deadline_id': source == 'ai' ? 10 : null,
  'source': source,
  'is_done': false,
};

final started = {
  'notice': {
    'id': 1,
    'title': '학점포기 신청 안내',
    'link': 'https://www.mju.ac.kr/bbs/mjukr/143/236065/artclView.do',
  },
  'apply_method': '기간 내 제출',
  'apply_method_evidence': '기간 내 신청하여 주시기 바랍니다',
  'unclear': ['undergrad', 'deadlines[0]'],
  'deadlines': [
    {
      'id': 10,
      'label': '신청',
      'deadline_date': '2026-10-16',
      'deadline_time': '18:00:00',
      'year_corrected': true,
      'confidence': '낮음',
      'evidence': '10.16(금) 18:00까지',
    },
  ],
  'tasks': [
    task(101, '재학증명서 발급', evidence: '재학증명서 1부'),
    task(102, '신청서 제출', evidence: '신청서 작성 후 제출'),
  ],
};

http.Response jsonResponse(Object? body, [int status = 200]) =>
    http.Response.bytes(
      body == null ? [] : utf8.encode(jsonEncode(body)),
      status,
      headers: {'content-type': 'application/json'},
    );

void usePhoneScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
}

void main() {
  homeTests();
  calendarTests();
  scheduleTests();
  myTasksTests();
  weeklyReviewTests();

  testWidgets('본문 폭: 휴대폰은 좌우 16 여백 그대로, 넓은 화면은 720으로 가운데', (tester) async {
    final client = MockClient((request) async => jsonResponse(notices));
    Future<Rect> cardRect(Size logicalSize) async {
      tester.view.physicalSize = logicalSize;
      tester.view.devicePixelRatio = 1.0;
      await tester.pumpWidget(
        MyApp(
          api: ApiClient(client: client, baseUrl: 'http://test'),
          initialTab: 1,
        ),
      );
      await tester.pumpAndSettle();
      return tester.getRect(find.byType(Card).first);
    }

    addTearDown(tester.view.reset);
    final phone = await cardRect(const Size(402, 874));
    expect((phone.left, phone.right), (16, 386));
    final wide = await cardRect(const Size(1440, 900));
    expect((wide.left, wide.right), (360, 1080));
    expect(find.byTooltip('새로고침'), findsNothing); // 웹에서만 보이는 버튼
  });

  test('서버 주소: 안드로이드는 10.0.2.2, iOS 등은 127.0.0.1', () {
    expect(
      ApiClient.defaultBaseUrl(platform: TargetPlatform.android),
      'http://10.0.2.2:8000',
    );
    expect(
      ApiClient.defaultBaseUrl(platform: TargetPlatform.iOS),
      'http://127.0.0.1:8000',
    );
    expect(
      ApiClient.defaultBaseUrl(platform: TargetPlatform.macOS),
      'http://127.0.0.1:8000',
    );
  });

  testWidgets('이거 할래 → 로딩 → 근거·확인 불가·원문 링크 → 수정(PATCH)·추가·삭제 → 저장', (
    tester,
  ) async {
    usePhoneScreen(tester);
    final startResponse = Completer<http.Response>();
    final requests = <String>[];
    final client = MockClient((request) async {
      final path = request.url.path;
      final key = '${request.method} $path';
      if (key != 'GET /notices') requests.add('$key ${request.body}');
      switch (key) {
        case 'GET /notices':
          return jsonResponse(notices);
        case 'POST /notices/1/tasks':
          return startResponse.future;
        case 'PATCH /tasks/101':
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse(
            task(
              101,
              body['title'] as String,
              evidence: '재학증명서 1부',
              note: body['note'] as String?,
            ),
          );
        case 'POST /notices/1/tasks/items':
          return jsonResponse(task(103, '부모님께 말씀드리기', source: 'user'), 201);
        case 'DELETE /tasks/102':
          return jsonResponse(null, 204);
        case 'POST /notices/1/tasks/confirm':
          return jsonResponse([]);
      }
      return jsonResponse({'detail': 'unexpected $key'}, 404);
    });

    await tester.pumpWidget(
      MyApp(
        api: ApiClient(client: client, baseUrl: 'http://test'),
        initialTab: 1,
      ),
    );
    await tester.pumpAndSettle();

    // 카드: 분석된 공지는 버튼 활성, 분석 전 공지는 비활성
    expect(find.text('학점포기 신청 안내'), findsOneWidget);
    expect(find.text('신청 2026-10-16 18:00'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '분석 중'))
          .onPressed,
      isNull,
    );

    // 이거 할래 → POST를 기다리는 동안 로딩 표시, 원문 링크는 그때도 보임
    await tester.tap(find.text('이거 할래'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('할 일을 정리하는 중…'), findsOneWidget);
    expect(find.text('원문 보기'), findsOneWidget);
    expect(find.text('저장'), findsNothing);

    startResponse.complete(jsonResponse(started));
    await tester.pumpAndSettle();

    // 확인 불가 경고, 마감·신청 방식·할 일의 근거
    expect(
      find.textContaining('확인하지 못한 항목이 있어요: 학부생 대상 여부, 마감일(신청)'),
      findsOneWidget,
    );
    expect(find.text('신청 · 2026-10-16 18:00'), findsOneWidget);
    expect(find.text('확인 필요'), findsOneWidget); // 확신도 낮은 마감
    expect(find.text('근거: 10.16(금) 18:00까지'), findsOneWidget);
    expect(find.text('근거: 기간 내 신청하여 주시기 바랍니다'), findsOneWidget);
    expect(find.text('근거: 재학증명서 1부'), findsOneWidget);
    expect(find.text('원문 보기'), findsOneWidget);

    // 항목을 눌러 수정 → PATCH
    await tester.tap(find.text('재학증명서 발급'));
    await tester.pumpAndSettle();
    expect(find.text('할 일 수정'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, '할 일'),
      '재학증명서 온라인 발급',
    );
    await tester.enterText(find.widgetWithText(TextField, '메모 (선택)'), '학생증 필요');
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();
    expect(find.text('재학증명서 온라인 발급'), findsOneWidget);
    expect(find.text('메모: 학생증 필요'), findsOneWidget);

    // 빈 제목이면 확인 버튼 비활성
    await tester.tap(find.text('재학증명서 온라인 발급'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '할 일'), '  ');
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '확인'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();

    // 삭제 (확인 대화상자)
    await tester.tap(find.byTooltip('삭제').at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, '삭제'));
    await tester.pumpAndSettle();
    expect(find.text('신청서 제출'), findsNothing);

    // 직접 추가
    await tester.ensureVisible(find.text('할 일 추가'));
    await tester.tap(find.text('할 일 추가'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '할 일'), '부모님께 말씀드리기');
    await tester.pump(); // 입력 후 다시 그려져야 확인 버튼이 활성화됨
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();
    expect(find.text('직접 추가한 할 일'), findsOneWidget);

    expect(requests, [
      'POST /notices/1/tasks ',
      'PATCH /tasks/101 {"title":"재학증명서 온라인 발급","note":"학생증 필요"}',
      'DELETE /tasks/102 ',
      'POST /notices/1/tasks/items {"title":"부모님께 말씀드리기","note":null}',
    ]);

    // 저장 → confirm 호출 후 목록으로 돌아와 안내
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    expect(requests.last, 'POST /notices/1/tasks/confirm ');
    expect(find.text('할 일을 저장했어요'), findsOneWidget);
    expect(find.widgetWithText(AppBar, '공지'), findsOneWidget);
  });

  testWidgets('저장하지 않고 뒤로 가면 confirm을 부르지 않고 목록도 그대로', (tester) async {
    usePhoneScreen(tester);
    final requests = <String>[];
    final client = MockClient((request) async {
      requests.add('${request.method} ${request.url.path}');
      if (request.url.path == '/notices') return jsonResponse(notices);
      if (request.method == 'POST' && request.url.path == '/notices/1/tasks') {
        return jsonResponse(started);
      }
      return jsonResponse({'detail': 'unexpected'}, 404);
    });
    await tester.pumpWidget(
      MyApp(
        api: ApiClient(client: client, baseUrl: 'http://test'),
        initialTab: 1,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('이거 할래'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('이거 할래'), findsOneWidget);
    expect(find.text('할 일을 저장했어요'), findsNothing);
    expect(requests, ['GET /notices', 'POST /notices/1/tasks']);
  });

  testWidgets('저장 실패 시 화면에 남아 오류 안내', (tester) async {
    usePhoneScreen(tester);
    final client = MockClient((request) async {
      if (request.url.path == '/notices') return jsonResponse(notices);
      if (request.url.path == '/notices/1/tasks') return jsonResponse(started);
      return jsonResponse({'detail': '서버 오류'}, 500);
    });
    await tester.pumpWidget(
      MyApp(
        api: ApiClient(client: client, baseUrl: 'http://test'),
        initialTab: 1,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('이거 할래'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    expect(find.text('저장하지 못했어요: 서버 오류'), findsOneWidget);
    expect(find.text('근거: 재학증명서 1부'), findsOneWidget);
  });

  testWidgets('수정 실패 시 원래 값 유지와 오류 안내', (tester) async {
    usePhoneScreen(tester);
    final client = MockClient((request) async {
      if (request.url.path == '/notices') return jsonResponse(notices);
      if (request.method == 'POST') return jsonResponse(started);
      return jsonResponse({'detail': '제목은 비워 둘 수 없습니다'}, 400);
    });
    await tester.pumpWidget(
      MyApp(
        api: ApiClient(client: client, baseUrl: 'http://test'),
        initialTab: 1,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('이거 할래'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('재학증명서 발급'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '할 일'), '바뀐 제목');
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();
    expect(find.text('재학증명서 발급'), findsOneWidget);
    expect(find.text('바뀐 제목'), findsNothing);
    expect(find.text('수정하지 못했어요: 제목은 비워 둘 수 없습니다'), findsOneWidget);
  });

  testWidgets('공지 목록 자동 갱신: 1분마다 로딩 표시 없이 바뀌고, 실패하면 보던 목록 유지', (tester) async {
    var analyzed = false;
    var fail = false;
    final client = MockClient((request) async {
      if (fail) return jsonResponse({'detail': '서버 오류'}, 500);
      return jsonResponse([
        for (final n in notices) {...n, if (analyzed) 'analyzed': true},
      ]);
    });
    await tester.pumpWidget(
      MyApp(
        api: ApiClient(client: client, baseUrl: 'http://test'),
        initialTab: 1,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('분석 중'), findsOneWidget);

    analyzed = true;
    await tester.pump(const Duration(minutes: 1));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('분석 중'), findsNothing);
    expect(find.text('이거 할래'), findsNWidgets(2));

    fail = true;
    await tester.pump(const Duration(minutes: 1));
    await tester.pumpAndSettle();
    expect(find.text('서버 오류'), findsNothing);
    expect(find.text('이거 할래'), findsNWidgets(2));
  });

  testWidgets('불러오기 실패 시 메시지와 다시 시도', (tester) async {
    var attempts = 0;
    final client = MockClient((request) async {
      if (request.url.path == '/notices') return jsonResponse(notices);
      attempts++;
      return attempts == 1
          ? jsonResponse({'detail': '할 일 분해 실패: Gemini 호출 실패'}, 502)
          : jsonResponse(started);
    });
    await tester.pumpWidget(
      MyApp(
        api: ApiClient(client: client, baseUrl: 'http://test'),
        initialTab: 1,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('이거 할래'));
    await tester.pumpAndSettle();
    expect(find.text('할 일 분해 실패: Gemini 호출 실패'), findsOneWidget);
    expect(find.text('저장'), findsNothing);
    expect(find.text('원문 보기'), findsOneWidget);

    await tester.tap(find.text('다시 시도'));
    await tester.pumpAndSettle();
    expect(find.text('근거: 재학증명서 1부'), findsOneWidget);
  });
}

Map<String, dynamic> myTask(
  int id,
  String title, {
  String? date,
  String? time,
  String label = '신청',
  bool done = false,
  bool fromNotice = false,
  String? scheduled,
}) => {
  'id': id,
  'title': title,
  'note': null,
  'is_done': done,
  'done_at': null,
  'source': 'ai',
  'notice': {'id': 1, 'title': '학점포기 신청 안내', 'link': 'https://example.com/1'},
  'deadline': date == null
      ? null
      : {
          'id': id * 10,
          'label': label,
          'deadline_date': date,
          'deadline_time': time,
        },
  'deadline_from_notice': fromNotice,
  'scheduled_date': scheduled,
};

void myTasksTests() {
  test('D-day는 기기 날짜 기준 일수 차이', () {
    final today = DateTime(2026, 10, 28, 23, 59);
    expect(daysLeft('2026-10-28', today), 0);
    expect(daysLeft('2026-10-31', today), 3);
    expect(daysLeft('2026-10-27', today), -1);
    expect(daysLeft('2027-01-01', today), 65);
  });

  testWidgets('내 할 일 탭: 임박 강조, 완료 묶음, 체크하면 바로 반영', (tester) async {
    usePhoneScreen(tester);
    final patches = <String>[];
    final client = MockClient((request) async {
      final key = '${request.method} ${request.url.path}';
      if (key == 'GET /notices') return jsonResponse(notices);
      if (key == 'GET /tasks') {
        return jsonResponse([
          myTask(
            1,
            '재학증명서 발급',
            date: '2026-10-30',
            time: '18:00:00',
            scheduled: '2026-10-28',
          ),
          myTask(
            2,
            '추천서 받기',
            date: '2026-11-20',
            fromNotice: true,
            scheduled: '2026-11-17',
          ),
          myTask(3, '직접 추가한 일'),
          myTask(5, '지난 신청', date: '2026-10-27', scheduled: '2026-10-24'),
          myTask(
            4,
            '신청서 작성',
            date: '2026-10-20',
            done: true,
            scheduled: '2026-10-17',
          ),
        ]);
      }
      if (request.method == 'PATCH') {
        patches.add('${request.url.path} ${request.body}');
        return request.url.path == '/tasks/2'
            ? jsonResponse({'detail': '서버 오류'}, 500)
            : jsonResponse({});
      }
      return jsonResponse({'detail': 'unexpected $key'}, 404);
    });
    await tester.pumpWidget(
      MyApp(
        api: ApiClient(client: client, baseUrl: 'http://test'),
        initialTab: 1,
        today: DateTime(2026, 10, 28),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('내 할 일').last);
    await tester.pumpAndSettle();

    // 남은 할 일(서버 순서) → 완료 묶음
    expect(find.widgetWithText(AppBar, '내 할 일'), findsOneWidget);
    expect(find.text('D-2 · 신청 10/30 18:00'), findsOneWidget);
    expect(find.text('D-23 · 공지 마감(신청) 11/20'), findsOneWidget);
    expect(find.text('완료 1개'), findsOneWidget);
    expect(find.text('학점포기 신청 안내'), findsNWidgets(5)); // 어느 공지에서 왔는지
    double y(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(y('재학증명서 발급') < y('추천서 받기'), isTrue);
    expect(y('직접 추가한 일') < y('완료 1개'), isTrue);
    expect(y('완료 1개') < y('신청서 작성'), isTrue);

    // 임박(D-3 이내)만 경고 색
    final urgent = tester.widget<InfoChip>(
      find.ancestor(
        of: find.text('D-2 · 신청 10/30 18:00'),
        matching: find.byType(InfoChip),
      ),
    );
    final normal = tester.widget<InfoChip>(
      find.ancestor(
        of: find.text('D-23 · 공지 마감(신청) 11/20'),
        matching: find.byType(InfoChip),
      ),
    );
    expect(urgent.urgent, isTrue);
    expect(normal.urgent, isFalse);

    // 서버가 배정한 날짜: 오늘/내일/날짜, 지난 날짜, 완료한 일은 표시 안 함
    expect(find.text('오늘 하기'), findsOneWidget);
    expect(find.text('11/17에 하기'), findsOneWidget);
    expect(find.text('10/24에 하기로 했던 일'), findsOneWidget);
    expect(find.text('10/17에 하기'), findsNothing);

    // 마감 지난 할 일은 회색 + 취소선 (완료는 아님)
    final overdue = tester.widget<Text>(find.text('지난 신청')).style!;
    expect(overdue.decoration, TextDecoration.lineThrough);
    expect(find.text('마감 지남 · 신청 10/27'), findsOneWidget);
    final active = tester.widget<Text>(find.text('추천서 받기')).style!;
    expect(active.decoration, isNot(TextDecoration.lineThrough));

    // 체크: 바로 완료 묶음으로 이동하고 PATCH
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    expect(find.text('완료 2개'), findsOneWidget);
    expect(patches, ['/tasks/1 {"is_done":true}']);

    // 서버 반영 실패: 되돌리고 안내
    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text('추천서 받기'),
          matching: find.byType(MyTaskTile),
        ),
        matching: find.byType(Checkbox),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('반영하지 못했어요: 서버 오류'), findsOneWidget);
    expect(find.text('완료 2개'), findsOneWidget);
    expect(find.text('D-23 · 공지 마감(신청) 11/20'), findsOneWidget);
  });
}

void weeklyReviewTests() {
  testWidgets('주간 회고: 완료율·끝내지 못한 일, 메모 저장(실패 시 유지), 지난 주 이동', (tester) async {
    usePhoneScreen(tester);
    final requests = <String>[];
    String? savedMemo;
    var failNextSave = true;
    Map<String, dynamic> review(
      String start,
      String end, {
      bool empty = false,
    }) => {
      'week_start': start,
      'week_end': end,
      'planned': empty ? 0 : 5,
      'done': empty ? 0 : 3,
      'rate': empty ? null : 0.6,
      'unfinished': empty
          ? []
          : [
              {
                'id': 1,
                'title': '추천서 받기',
                'scheduled_date': '2026-11-03',
                'notice': {
                  'id': 1,
                  'title': '장학생 선발 안내',
                  'link': 'https://example.com/1',
                },
              },
              {
                'id': 2,
                'title': '서류 제출',
                'scheduled_date': '2026-11-05',
                'notice': {
                  'id': 1,
                  'title': '장학생 선발 안내',
                  'link': 'https://example.com/1',
                },
              },
            ],
      'memo': empty ? null : savedMemo,
      'updated_at': null,
    };
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path == '/tasks') return jsonResponse([]);
      if (path == '/reviews/weekly') {
        final week = request.url.queryParameters['week'];
        requests.add(
          '${request.method} ${week ?? '이번 주'} ${request.body}'.trim(),
        );
        if (request.method == 'PUT') {
          if (failNextSave) {
            failNextSave = false;
            return jsonResponse({'detail': '서버 오류'}, 500);
          }
          savedMemo = (jsonDecode(request.body) as Map)['memo'] as String;
        }
        return week == '2026-10-25'
            ? jsonResponse(review('2026-10-25', '2026-10-31', empty: true))
            : jsonResponse(review('2026-11-01', '2026-11-07'));
      }
      return jsonResponse({'detail': 'unexpected $path'}, 404);
    });
    await tester.pumpWidget(
      MyApp(
        api: ApiClient(client: client, baseUrl: 'http://test'),
        initialTab: 1,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('내 할 일').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('이번 주 회고'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(AppBar, '이번 주 회고'), findsOneWidget);
    expect(find.text('11/1 ~ 11/7'), findsOneWidget);
    expect(find.text('5개 중 3개 완료'), findsOneWidget);
    expect(find.text('60%'), findsOneWidget);
    expect(find.text('끝내지 못한 일 2개'), findsOneWidget);
    expect(find.text('추천서 받기'), findsOneWidget);
    expect(find.text('11/5'), findsOneWidget);
    IconButton arrow(IconData icon) =>
        tester.widget<IconButton>(find.widgetWithIcon(IconButton, icon));
    expect(arrow(Icons.chevron_right).onPressed, isNull); // 이번 주보다 뒤로는 못 감
    FilledButton saveButton() =>
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, '저장'));
    expect(saveButton().onPressed, isNull); // 바뀐 내용이 없으면 저장 비활성

    // 저장 실패: 쓴 내용은 그대로, 다시 누르면 저장
    await tester.enterText(find.byType(TextField), '추천서를 늦게 부탁드려서 못 받음');
    await tester.pump();
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    expect(find.text('저장하지 못했어요: 서버 오류'), findsOneWidget);
    expect(find.text('추천서를 늦게 부탁드려서 못 받음'), findsOneWidget);
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    expect(find.text('저장했어요'), findsOneWidget);
    expect(saveButton().onPressed, isNull);

    // 지난 주로: 계획이 없는 주, 다음 주(이번 주)로 돌아올 수 있음
    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, '주간 회고'), findsOneWidget);
    expect(find.text('10/25 ~ 10/31'), findsOneWidget);
    expect(find.text('이 주에 하기로 한 할 일이 없어요'), findsOneWidget);
    expect(find.text('끝내지 못한 일 0개'), findsNothing);

    // 저장하지 않은 메모가 있으면 이동 전에 물어봄
    await tester.enterText(find.byType(TextField), '지난 주 메모');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    expect(find.text('저장하지 않은 메모가 있어요'), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(find.text('10/25 ~ 10/31'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pumpAndSettle();
    await tester.tap(find.text('이동'));
    await tester.pumpAndSettle();
    expect(find.text('11/1 ~ 11/7'), findsOneWidget);
    expect(find.text('추천서를 늦게 부탁드려서 못 받음'), findsOneWidget); // 저장한 메모

    expect(requests, [
      'GET 이번 주',
      'PUT 2026-11-01 {"memo":"추천서를 늦게 부탁드려서 못 받음"}',
      'PUT 2026-11-01 {"memo":"추천서를 늦게 부탁드려서 못 받음"}',
      'GET 2026-10-25',
      'GET 2026-11-01',
    ]);
  });
}

void homeTests() {
  final today = DateTime(2026, 10, 28);
  List<MyTask> parse(List<Map<String, dynamic>> items) => [
    for (final t in items) MyTask.fromJson(t),
  ];

  test('오늘 할 일: 오늘 것은 완료 포함, 지난 것은 미완료만, 미완료가 위·예정일 빠른 순', () {
    final tasks = parse([
      myTask(1, '오늘 완료', scheduled: '2026-10-28', done: true),
      myTask(2, '오늘 남음', scheduled: '2026-10-28'),
      myTask(3, '지난 미완료', scheduled: '2026-10-26'),
      myTask(4, '지난 완료', scheduled: '2026-10-26', done: true),
      myTask(5, '내일', scheduled: '2026-10-29'),
      myTask(6, '예정일 없음'),
      myTask(7, '더 지난 미완료', scheduled: '2026-10-20'),
      myTask(8, '오늘 남음 2', scheduled: '2026-10-28'),
    ]);
    expect([for (final t in todayTasks(tasks, today)) t.id], [7, 3, 2, 8, 1]);
  });

  test('가장 가까운 마감: 미완료 할 일의 마감 중 오늘 이후 가장 가까운 것', () {
    final tasks = parse([
      myTask(1, '지난 마감', date: '2026-10-27'),
      myTask(2, '완료한 일', date: '2026-10-29', done: true),
      myTask(3, '다음 주', date: '2026-11-02'),
      myTask(4, '시각 없음', date: '2026-10-31'),
      myTask(5, '같은 날 18시', date: '2026-10-31', time: '18:00:00'),
      myTask(6, '마감 없음'),
    ]);
    expect(nearestDeadline(tasks, today)?.id, 5);
    expect(nearestDeadline(tasks.sublist(0, 2), today), isNull);
    expect(
      nearestDeadline(
        parse([myTask(9, '오늘 마감', date: '2026-10-28')]),
        today,
      )?.id,
      9,
    );
  });

  Map<String, dynamic> week(int planned, int done) => {
    'week_start': '2026-10-25',
    'week_end': '2026-10-31',
    'planned': planned,
    'done': done,
    'rate': planned == 0 ? null : done / planned,
    'unfinished': [],
    'memo': null,
    'updated_at': null,
  };

  testWidgets('홈: 요약, 오늘·지남 표시와 순서, 체크 반영(실패 시 되돌림), 회고 이동, 새 공지', (
    tester,
  ) async {
    usePhoneScreen(tester);
    final requests = <String>[];
    var done = 1;
    final client = MockClient((request) async {
      final key = '${request.method} ${request.url.path}';
      switch (key) {
        case 'GET /notices':
          requests.add('GET /notices?${request.url.query}');
          return jsonResponse([
            for (var i = 1; i <= 3; i++)
              {...notices[0], 'id': i, 'title': '새 공지 $i'},
          ]);
        case 'GET /tasks':
          return jsonResponse([
            myTask(
              1,
              '성적표 준비',
              date: '2026-11-05',
              scheduled: '2026-10-28',
              done: true,
            ),
            myTask(
              2,
              '신청서 제출',
              date: '2026-10-30',
              time: '18:00:00',
              scheduled: '2026-10-28',
            ),
            myTask(3, '재학증명서 발급', date: '2026-11-02', scheduled: '2026-10-26'),
            myTask(4, '면담 예약', date: '2026-11-02', scheduled: '2026-10-29'),
          ]);
        case 'GET /reviews/weekly':
          return jsonResponse(week(4, done));
        case 'PATCH /tasks/2':
          requests.add('$key ${request.body}');
          done = 2;
          return jsonResponse(task(2, '신청서 제출'));
        case 'PATCH /tasks/3':
          requests.add('$key ${request.body}');
          return jsonResponse({'detail': '서버 오류'}, 500);
        case 'POST /notices/1/tasks':
          return jsonResponse(started);
      }
      return jsonResponse({'detail': 'unexpected $key'}, 404);
    });
    await tester.pumpWidget(
      MyApp(
        api: ApiClient(client: client, baseUrl: 'http://test'),
        today: today,
      ),
    );
    await tester.pumpAndSettle();

    // 요약 3개
    expect(find.text('D-2 · 학점포기 신청 안내'), findsOneWidget);
    expect(find.text('신청 10/30 18:00'), findsOneWidget);
    expect(find.text('1개 남음'), findsOneWidget);
    expect(find.text('지난 할 일 1개'), findsOneWidget);
    expect(find.text('4개 중 1개 완료 · 25%'), findsOneWidget);
    expect(requests, ['GET /notices?limit=3']);

    // 오늘 할 일: 지난 미완료 → 오늘 미완료 → 오늘 완료. 내일 것은 없음
    double y(String title) => tester.getTopLeft(find.text(title)).dy;
    expect(y('재학증명서 발급') < y('신청서 제출'), isTrue);
    expect(y('신청서 제출') < y('성적표 준비'), isTrue);
    expect(find.text('면담 예약'), findsNothing);
    expect(find.text('지남 · 10/26'), findsOneWidget);
    expect(find.text('오늘'), findsOneWidget);
    expect(find.text('학점포기 신청 안내'), findsNWidgets(3)); // 어느 공지의 할 일인지

    Finder checkbox(String title) => find.descendant(
      of: find.widgetWithText(MyTaskTile, title),
      matching: find.byType(Checkbox),
    );

    // 체크하면 바로 반영되고 요약도 바뀜. 목록에는 그대로 남아 아래로 내려감
    await tester.tap(checkbox('신청서 제출'));
    await tester.pumpAndSettle();
    expect(requests.last, 'PATCH /tasks/2 {"is_done":true}');
    expect(find.text('오늘 할 일을 모두 끝냈어요'), findsOneWidget);
    expect(find.text('4개 중 2개 완료 · 50%'), findsOneWidget);
    expect(tester.widget<Checkbox>(checkbox('신청서 제출')).value, isTrue);

    // 실패하면 되돌리고 안내
    await tester.tap(checkbox('재학증명서 발급'));
    await tester.pumpAndSettle();
    expect(requests.last, 'PATCH /tasks/3 {"is_done":true}');
    expect(find.text('반영하지 못했어요: 서버 오류'), findsOneWidget);
    expect(tester.widget<Checkbox>(checkbox('재학증명서 발급')).value, isFalse);
    expect(find.text('지난 할 일 1개'), findsOneWidget);

    // 완료율을 누르면 회고 화면
    await tester.tap(find.text('이번 주 완료율'));
    await tester.pumpAndSettle();
    expect(find.text('이번 주 회고'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // 새 공지 3개와 '이거 할래'
    final list = find.byType(Scrollable).first;
    for (var i = 1; i <= 3; i++) {
      await tester.scrollUntilVisible(
        find.text('새 공지 $i'),
        200,
        scrollable: list,
      );
    }
    await tester.scrollUntilVisible(
      find.text('이거 할래').first,
      -200,
      scrollable: list,
    );
    await tester.tap(find.text('이거 할래').first);
    await tester.pumpAndSettle();
    expect(find.text('근거: 재학증명서 1부'), findsOneWidget);
  });

  testWidgets('홈: 비어 있으면 구역마다 안내 문구, 불러오기 실패 시 다시 시도', (tester) async {
    usePhoneScreen(tester);
    var fail = true;
    var taskLoads = 0;
    var hasNotice = false;
    final client = MockClient((request) async {
      switch (request.url.path) {
        case '/tasks':
          taskLoads++;
          return fail
              ? jsonResponse({'detail': '서버 오류'}, 500)
              : jsonResponse([]);
        case '/reviews/weekly':
          return jsonResponse(week(0, 0));
      }
      return jsonResponse(hasNotice ? notices : []);
    });
    await tester.pumpWidget(
      MyApp(
        api: ApiClient(client: client, baseUrl: 'http://test'),
        today: today,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('서버 오류'), findsOneWidget);

    fail = false;
    await tester.tap(find.text('다시 시도'));
    await tester.pumpAndSettle();
    expect(find.text('다가오는 마감이 없어요'), findsOneWidget);
    expect(find.text('오늘 할 일이 없어요'), findsNWidgets(2)); // 요약과 목록
    expect(find.text('이번 주에 하기로 한 일이 없어요'), findsOneWidget);
    expect(find.text('새 공지가 없어요'), findsOneWidget);

    // 자동 갱신: 새 공지만 다시 불러오고 할 일은 그대로 둠
    hasNotice = true;
    final loadsBefore = taskLoads;
    await tester.pump(const Duration(minutes: 1));
    await tester.pumpAndSettle();
    expect(find.text('새 공지가 없어요'), findsNothing);
    expect(find.text('학점포기 신청 안내'), findsOneWidget);
    expect(taskLoads, loadsBefore);
  });
}

Map<String, dynamic> myDeadline(
  int id,
  String label,
  String date, {
  String? time,
  String title = '학점포기 신청 안내',
}) => {
  'id': id,
  'label': label,
  'deadline_date': date,
  'deadline_time': time,
  'notice': {'id': 1, 'title': title, 'link': 'https://example.com/1'},
};

void calendarTests() {
  final today = DateTime(2026, 10, 28); // 수요일

  test('달력 칸: 일요일 시작, 1일 앞과 말일 뒤는 빈칸, 7의 배수', () {
    int lead(List<DateTime?> cells) => cells.indexWhere((d) => d != null);
    int days(List<DateTime?> cells) => cells.whereType<DateTime>().length;
    final oct = monthCells(2026, 10); // 1일이 목요일
    expect((lead(oct), days(oct), oct.length), (4, 31, 35));
    expect(oct[4], DateTime(2026, 10, 1));
    expect(oct.last, DateTime(2026, 10, 31));
    final feb = monthCells(2026, 2); // 1일이 일요일인 28일짜리 달
    expect((lead(feb), days(feb), feb.length), (0, 28, 28));
    final jan = monthCells(2027, 1); // 1일이 금요일 → 6주
    expect((lead(jan), days(jan), jan.length), (5, 31, 42));
    expect(days(monthCells(2028, 2)), 29); // 윤년
    expect(
      monthCells(2026, 12).whereType<DateTime>().last,
      DateTime(2026, 12, 31),
    );
  });

  test('날짜별 표시와 묶기: 할 일 예정일(미완료·완료)과 마감일', () {
    final tasks = [
      for (final t in [
        myTask(1, '완료한 일', scheduled: '2026-10-28', done: true),
        myTask(2, '남은 일', scheduled: '2026-10-28'),
        myTask(3, '다른 날 완료', scheduled: '2026-10-26', done: true),
        myTask(4, '예정일 없음'),
      ])
        MyTask.fromJson(t),
    ];
    final deadlines = [
      for (final d in [
        myDeadline(10, '신청', '2026-10-30', time: '18:00:00'),
        myDeadline(11, '서류', '2026-10-28'),
        myDeadline(12, '면접', '2026-11-05'),
      ])
        MyDeadline.fromJson(d),
    ];
    final marks = calendarMarks(tasks, deadlines);
    expect(marks['2026-10-28'], (todo: true, done: true, deadline: true));
    expect(marks['2026-10-26'], (todo: false, done: true, deadline: false));
    expect(marks['2026-10-30'], (todo: false, done: false, deadline: true));
    expect(marks.containsKey('2026-10-29'), isFalse);
    expect([for (final t in tasksOn(tasks, '2026-10-28')) t.id], [2, 1]);
    expect([for (final d in deadlinesIn(deadlines, 2026, 10)) d.id], [10, 11]);
    expect([for (final d in deadlinesIn(deadlines, 2026, 11)) d.id], [12]);
    expect(deadlinesIn(deadlines, 2026, 1), isEmpty);
  });

  testWidgets('캘린더: 오늘·표시, 날짜를 누르면 그날 목록, 체크 반영, 달 이동과 그 달의 마감', (
    tester,
  ) async {
    usePhoneScreen(tester);
    final requests = <String>[];
    final client = MockClient((request) async {
      final key = '${request.method} ${request.url.path}';
      switch (key) {
        case 'GET /tasks':
          return jsonResponse([
            myTask(1, '성적표 준비', scheduled: '2026-10-28', done: true),
            myTask(2, '신청서 제출', scheduled: '2026-10-28'),
            myTask(3, '재학증명서 발급', scheduled: '2026-10-26', done: true),
          ]);
        case 'GET /deadlines':
          return jsonResponse([
            myDeadline(10, '신청', '2026-10-30', time: '18:00:00'),
            myDeadline(11, '면접', '2026-11-05', title: '장학생 선발 안내'),
          ]);
        case 'PATCH /tasks/2':
          requests.add('$key ${request.body}');
          return jsonResponse(task(2, '신청서 제출'));
      }
      return jsonResponse({'detail': 'unexpected $key'}, 404);
    });
    await tester.pumpWidget(
      MyApp(
        api: ApiClient(client: client, baseUrl: 'http://test'),
        today: today,
        initialTab: 2,
      ),
    );
    await tester.pumpAndSettle();
    Finder key(String k) => find.byKey(ValueKey(k));

    // 이번 달과 오늘(처음 선택된 날)
    expect(find.text('2026년 10월'), findsOneWidget);
    expect(find.text('10월 28일 (수)'), findsOneWidget);
    expect(key('day-2026-10-01'), findsOneWidget);
    expect(key('day-2026-11-01'), findsNothing);

    // 표시: 28일은 미완료·완료, 26일은 완료만, 30일은 마감만
    expect(key('todo-2026-10-28'), findsOneWidget);
    expect(key('done-2026-10-28'), findsOneWidget);
    expect(key('deadline-2026-10-28'), findsNothing);
    expect(key('todo-2026-10-26'), findsNothing);
    expect(key('done-2026-10-26'), findsOneWidget);
    expect(key('deadline-2026-10-30'), findsOneWidget);

    // 오늘의 목록(미완료가 위)과 이번 달 마감
    double y(String title) => tester.getTopLeft(find.text(title)).dy;
    expect(y('신청서 제출') < y('성적표 준비'), isTrue);
    expect(find.text('이번 달 마감'), findsOneWidget);
    expect(find.text('10/30'), findsOneWidget);
    expect(find.text('신청 18:00'), findsOneWidget);
    expect(find.text('D-2'), findsOneWidget);
    expect(find.text('장학생 선발 안내'), findsNothing); // 11월 마감

    // 체크하면 바로 반영되고 그날의 미완료 표시가 사라짐
    await tester.tap(
      find.descendant(
        of: find.widgetWithText(MyTaskTile, '신청서 제출'),
        matching: find.byType(Checkbox),
      ),
    );
    await tester.pumpAndSettle();
    expect(requests, ['PATCH /tasks/2 {"is_done":true}']);
    expect(key('todo-2026-10-28'), findsNothing);
    expect(key('done-2026-10-28'), findsOneWidget);

    // 다른 날짜를 누르면 그날 목록
    await tester.tap(key('day-2026-10-30'));
    await tester.pumpAndSettle();
    expect(find.text('10월 30일 (금)'), findsOneWidget);
    expect(find.text('신청서 제출'), findsNothing);
    expect(find.text('신청 18:00'), findsNWidgets(2)); // 그날 목록과 이번 달 마감
    await tester.tap(key('day-2026-10-29'));
    await tester.pumpAndSettle();
    expect(find.text('이 날은 할 일과 마감이 없어요'), findsOneWidget);

    // 다음 달: 그 달의 마감, 선택은 풀림
    await tester.tap(find.byTooltip('다음 달'));
    await tester.pumpAndSettle();
    expect(find.text('2026년 11월'), findsOneWidget);
    expect(find.text('날짜를 누르면 그날의 할 일과 마감이 보여요'), findsOneWidget);
    expect(find.text('11월 마감'), findsOneWidget);
    expect(find.text('장학생 선발 안내'), findsOneWidget);
    expect(find.text('D-8'), findsOneWidget);
    expect(key('deadline-2026-11-05'), findsOneWidget);

    // 이전 달로 두 번: 마감 없는 달. 이번 달로 돌아오면 오늘이 다시 선택됨
    await tester.tap(find.byTooltip('이전 달'));
    await tester.pumpAndSettle();
    expect(find.text('10월 28일 (수)'), findsOneWidget);
    await tester.tap(find.byTooltip('이전 달'));
    await tester.pumpAndSettle();
    expect(find.text('2026년 9월'), findsOneWidget);
    expect(find.text('9월 마감'), findsOneWidget);
    expect(find.text('마감이 없어요'), findsOneWidget);
  });
}

void scheduleTests() {
  final today = DateTime(2026, 10, 28);
  final examRef = {
    'id': 9,
    'kind': 'exam',
    'title': '자료구조 중간고사',
    'target_date': '2026-11-12',
  };
  Map<String, dynamic> item(
    int id,
    String title,
    String? phase,
    String? scheduled, {
    bool done = false,
  }) => {
    'id': id,
    'title': title,
    'note': null,
    'phase': phase,
    'scheduled_date': scheduled,
    'is_done': done,
    'source': 'user',
  };

  testWidgets('일정: 목록 → 등록(날짜 선택) → 상세에서 완료·추가·수정·삭제 → 일정 수정·삭제', (
    tester,
  ) async {
    usePhoneScreen(tester);
    final requests = <String>[];
    var title = '자료구조 중간고사';
    var date = '2026-11-12';
    var tasks = [
      item(1, '시험 범위와 출제 유형 확인', '준비', '2026-10-29'),
      item(2, '1회독: 개념 정리', '공부', '2026-11-04'),
      item(3, '암기 항목 최종 점검', '직전', '2026-11-11'),
    ];
    Map<String, dynamic> detail() => {
      'id': 9,
      'kind': 'exam',
      'title': title,
      'target_date': date,
      'phases': ['준비', '공부', '직전'],
      'tasks': tasks,
    };
    final client = MockClient((request) async {
      final key = '${request.method} ${request.url.path}';
      if (request.method != 'GET') requests.add('$key ${request.body}');
      switch (key) {
        case 'GET /schedules':
          requests.add(key);
          return jsonResponse([
            {
              'kind': 'notice',
              'schedule_id': null,
              'notice_id': 1,
              'link': 'https://example.com/1',
              'title': '학점포기 신청 안내',
              'date': '2026-10-30',
              'total': 2,
              'done': 1,
            },
            {
              'kind': 'contest',
              'schedule_id': 7,
              'notice_id': null,
              'link': null,
              'title': '캡스톤 공모전',
              'date': '2026-11-20',
              'total': 10,
              'done': 0,
            },
            {
              'kind': 'exam',
              'schedule_id': 8,
              'notice_id': null,
              'link': null,
              'title': '지난 시험',
              'date': '2026-10-20',
              'total': 0,
              'done': 0,
            },
          ]);
        case 'POST /schedules':
          return jsonResponse(detail(), 201);
        case 'GET /schedules/9':
          return jsonResponse(detail());
        case 'PATCH /schedules/9':
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          title = body['title'] as String;
          date = body['target_date'] as String;
          tasks[0] = item(1, '시험 범위와 출제 유형 확인', '준비', '2026-11-05');
          return jsonResponse(detail());
        case 'DELETE /schedules/9':
          return jsonResponse(null, 204);
        case 'POST /schedules/9/tasks':
          final added = item(4, '스터디 모임', '공부', '2026-10-30');
          tasks = [tasks[0], tasks[1], added, tasks[2]];
          return jsonResponse(added, 201);
        case 'PATCH /tasks/2':
          tasks[1] = item(2, '1회독: 개념 정리', '공부', '2026-11-04', done: true);
          return jsonResponse(tasks[1]);
        case 'PATCH /tasks/3':
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final i = tasks.indexWhere((t) => t['id'] == 3);
          tasks[i] = item(
            3,
            body['title'] as String,
            '직전',
            body['scheduled_date'] as String?,
          );
          return jsonResponse(tasks[i]);
        case 'DELETE /tasks/4':
          tasks.removeWhere((t) => t['id'] == 4);
          return jsonResponse(null, 204);
      }
      return jsonResponse({'detail': 'unexpected $key'}, 404);
    });
    await tester.pumpWidget(
      MyApp(
        api: ApiClient(client: client, baseUrl: 'http://test'),
        today: today,
        initialTab: 3,
      ),
    );
    await tester.pumpAndSettle();

    // 목록: 출처 태그, D-day, 진행률
    for (final tag in ['공지', '공모전', '시험']) {
      expect(find.widgetWithText(Tag, tag), findsOneWidget);
    }
    expect(find.text('D-2 · 10/30'), findsOneWidget);
    expect(find.text('1/2 완료'), findsOneWidget);
    expect(find.text('D-23 · 11/20'), findsOneWidget);
    expect(find.text('지남 · 10/20'), findsOneWidget);
    expect(find.text('할 일 없음'), findsOneWidget);

    // 등록: 제목과 날짜가 있어야 '등록'이 켜짐. 날짜는 달력 창에서 고름
    await tester.tap(find.text('일정 추가'));
    await tester.pumpAndSettle();
    FilledButton submit(String label) =>
        tester.widget(find.widgetWithText(FilledButton, label));
    expect(submit('등록').onPressed, isNull);
    await tester.enterText(find.byType(TextField), '자료구조 중간고사');
    await tester.tap(find.text('시험일 선택'));
    await tester.pumpAndSettle();
    expect(find.text('2026년 10월'), findsOneWidget);
    await tester.tap(find.byTooltip('다음 달'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pick-2026-11-12')));
    await tester.pumpAndSettle();
    expect(find.text('시험일 2026-11-12'), findsOneWidget);
    await tester.tap(find.text('등록'));
    await tester.pumpAndSettle();
    expect(
      requests.last,
      'POST /schedules {"kind":"exam","title":"자료구조 중간고사","target_date":"2026-11-12","use_checklist":true}',
    );

    // 상세: D-day, 진행률, 단계별 묶음, '직접 추가' 표시
    expect(find.text('D-15 · 시험일 11/12'), findsOneWidget);
    expect(find.text('3개 중 0개 완료'), findsOneWidget);
    double y(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(y('준비') < y('시험 범위와 출제 유형 확인'), isTrue);
    expect(y('시험 범위와 출제 유형 확인') < y('공부'), isTrue);
    expect(y('공부') < y('1회독: 개념 정리'), isTrue);
    expect(y('1회독: 개념 정리') < y('직전'), isTrue);
    expect(find.text('10/29에 하기'), findsOneWidget);
    expect(find.text('직접 추가'), findsNWidgets(3));

    Finder tile(String title) =>
        find.ancestor(of: find.text(title), matching: find.byType(Card));
    Finder inTile(String title, Finder what) =>
        find.descendant(of: tile(title), matching: what);

    // 완료
    await tester.tap(inTile('1회독: 개념 정리', find.byType(Checkbox)));
    await tester.pumpAndSettle();
    expect(requests.last, 'PATCH /tasks/2 {"is_done":true}');
    expect(find.text('3개 중 1개 완료'), findsOneWidget);
    expect(find.text('33%'), findsOneWidget);

    // 항목 추가: 단계와 예정일을 고름
    await tester.ensureVisible(find.text('항목 추가'));
    await tester.tap(find.text('항목 추가'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '스터디 모임');
    await tester.tap(find.text('공부').last);
    await tester.tap(find.text('예정일 선택'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pick-2026-10-30')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();
    expect(
      requests.last,
      'POST /schedules/9/tasks {"title":"스터디 모임","phase":"공부","scheduled_date":"2026-10-30"}',
    );
    expect(find.text('4개 중 1개 완료'), findsOneWidget);
    expect(y('1회독: 개념 정리') < y('스터디 모임'), isTrue);
    expect(y('스터디 모임') < y('직전'), isTrue);

    // 항목 수정: 제목과 예정일
    await tester.ensureVisible(inTile('암기 항목 최종 점검', find.byTooltip('수정')));
    await tester.tap(inTile('암기 항목 최종 점검', find.byTooltip('수정')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '암기 항목 점검');
    await tester.tap(find.text('예정일 2026-11-11'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('pick-2026-11-10')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();
    expect(
      requests.last,
      'PATCH /tasks/3 {"title":"암기 항목 점검","scheduled_date":"2026-11-10"}',
    );
    expect(find.text('11/10에 하기'), findsOneWidget);

    // 항목 삭제 (확인 창)
    await tester.ensureVisible(inTile('스터디 모임', find.byTooltip('삭제')));
    await tester.tap(inTile('스터디 모임', find.byTooltip('삭제')));
    await tester.pumpAndSettle();
    expect(find.text('항목을 삭제할까요?'), findsOneWidget);
    await tester.tap(find.text('삭제'));
    await tester.pumpAndSettle();
    expect(requests.last, 'DELETE /tasks/4 ');
    expect(find.text('스터디 모임'), findsNothing);

    // 일정 수정: 날짜를 바꾸면 서버가 다시 계산한 예정일이 보임
    await tester.tap(find.byTooltip('일정 수정'));
    await tester.pumpAndSettle();
    expect(find.text('일정 수정'), findsOneWidget);
    await tester.tap(find.text('시험일 2026-11-12'));
    await tester.pumpAndSettle();
    expect(find.text('2026년 11월'), findsOneWidget); // 지금 날짜의 달부터
    await tester.tap(find.byKey(const ValueKey('pick-2026-11-19')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    expect(
      requests.last,
      'PATCH /schedules/9 {"title":"자료구조 중간고사","target_date":"2026-11-19"}',
    );
    expect(find.text('D-22 · 시험일 11/19'), findsOneWidget);
    expect(find.text('11/5에 하기'), findsOneWidget);

    // 일정 삭제 (확인 창) → 목록으로 돌아와 다시 불러옴
    await tester.tap(find.byTooltip('일정 삭제'));
    await tester.pumpAndSettle();
    expect(find.text('일정을 삭제할까요?'), findsOneWidget);
    await tester.tap(find.text('삭제'));
    await tester.pumpAndSettle();
    expect(requests.sublist(requests.length - 2), [
      'DELETE /schedules/9 ',
      'GET /schedules',
    ]);
    expect(find.text('캡스톤 공모전'), findsOneWidget);
  });

  testWidgets('일정의 할 일: 홈·내 할 일·캘린더·주간 회고에 출처와 함께 나오고, 누르면 일정 상세', (
    tester,
  ) async {
    usePhoneScreen(tester);
    final opened = <String>[];
    final examTask = {
      ...myTask(50, '2회독: 문제 풀이', scheduled: '2026-10-28'),
      'source': 'user',
      'notice': null,
      'schedule': examRef,
      'deadline': {
        'id': null,
        'label': '시험일',
        'deadline_date': '2026-11-12',
        'deadline_time': null,
      },
    };
    final client = MockClient((request) async {
      switch (request.url.path) {
        case '/tasks':
          return jsonResponse([
            myTask(1, '신청서 제출', date: '2026-10-30', scheduled: '2026-10-28'),
            examTask,
          ]);
        case '/deadlines':
          return jsonResponse([
            myDeadline(10, '신청', '2026-10-30'),
            {
              'id': null,
              'label': '시험일',
              'deadline_date': '2026-11-12',
              'deadline_time': null,
              'notice': null,
              'schedule': examRef,
            },
          ]);
        case '/reviews/weekly':
          return jsonResponse({
            'week_start': '2026-10-25',
            'week_end': '2026-10-31',
            'planned': 2,
            'done': 0,
            'rate': 0.0,
            'unfinished': [
              {
                'id': 50,
                'title': '2회독: 문제 풀이',
                'scheduled_date': '2026-10-28',
                'notice': null,
                'schedule': examRef,
              },
            ],
            'memo': null,
            'updated_at': null,
          });
        case '/schedules/9':
          opened.add(request.url.path);
          return jsonResponse({
            ...examRef,
            'phases': ['준비', '공부', '직전'],
            'tasks': [item(50, '2회독: 문제 풀이', '공부', '2026-10-28')],
          });
      }
      return jsonResponse([]);
    });
    await tester.pumpWidget(
      MyApp(
        api: ApiClient(client: client, baseUrl: 'http://test'),
        today: today,
      ),
    );
    await tester.pumpAndSettle();
    const source = '시험 · 자료구조 중간고사';

    // 홈: 오늘 할 일에 출처와 함께. 가장 가까운 마감은 공지 쪽(10/30)
    expect(find.text('D-2 · 학점포기 신청 안내'), findsOneWidget);
    expect(find.text('2개 남음'), findsOneWidget);
    expect(find.text(source), findsOneWidget);

    // 내 할 일: 시험일이 마감으로 나오고, 누르면 일정 상세
    await tester.tap(find.text('내 할 일').last);
    await tester.pumpAndSettle();
    expect(find.text(source), findsOneWidget);
    expect(find.text('D-15 · 시험일 11/12'), findsOneWidget);
    await tester.tap(find.text('2회독: 문제 풀이'));
    await tester.pumpAndSettle();
    expect(opened, ['/schedules/9']);
    expect(find.text('1개 중 0개 완료'), findsOneWidget);
    expect(find.text('직접 추가'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // 주간 회고의 끝내지 못한 일
    await tester.tap(find.text('이번 주 회고'));
    await tester.pumpAndSettle();
    expect(find.text(source), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    // 캘린더: 오늘의 할 일, 다음 달에 시험일 표시와 그 달의 마감
    await tester.tap(find.text('캘린더'));
    await tester.pumpAndSettle();
    expect(find.text(source), findsOneWidget);
    await tester.tap(find.byTooltip('다음 달'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('deadline-2026-11-12')), findsOneWidget);
    expect(find.text(source), findsOneWidget);
    expect(find.text('시험일'), findsOneWidget);
    expect(find.text('D-15'), findsOneWidget);
  });
}
