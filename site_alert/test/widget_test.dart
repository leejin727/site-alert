import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:site_alert/api.dart';
import 'package:site_alert/main.dart';
import 'package:site_alert/screens/my_tasks_screen.dart';
import 'package:site_alert/screens/notice_list_screen.dart' show InfoChip;

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
  myTasksTests();
  weeklyReviewTests();

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
