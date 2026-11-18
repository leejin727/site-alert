import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'api.dart';
import 'screens/calendar_screen.dart';
import 'screens/home_screen.dart';
import 'screens/my_tasks_screen.dart';
import 'screens/notice_list_screen.dart';
import 'screens/schedule_list_screen.dart';

void main() {
  runApp(MyApp(api: ApiClient()));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, required this.api, this.today, this.initialTab = 0});

  final ApiClient api;
  final DateTime? today; // 테스트용 '오늘' (D-day 계산)
  final int initialTab; // 테스트용: 처음 열 탭

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '이거할래',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        // 웹은 한글 폰트가 없어 실행 중에 내려받으므로 내장 폰트를 씀. 휴대폰은 기기 기본 폰트 그대로.
        fontFamily: kIsWeb ? 'GowunDodum' : null,
        // 웹은 본문을 가운데로 모으므로 제목도 버튼 수와 상관없이 가운데에 둠
        appBarTheme: kIsWeb ? const AppBarTheme(centerTitle: true) : null,
      ),
      home: HomeShell(api: api, today: today, initialTab: initialTab),
    );
  }
}

/// 하단 탭: 홈 / 공지 / 캘린더 / 일정 / 내 할 일. 탭을 바꿀 때마다 그 화면을 새로 불러옴 (다른 탭에서 저장·체크한 내용 반영).
class HomeShell extends StatefulWidget {
  const HomeShell({
    super.key,
    required this.api,
    this.today,
    this.initialTab = 0,
  });

  final ApiClient api;
  final DateTime? today;
  final int initialTab;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  late int _index = widget.initialTab;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: switch (_index) {
        0 => HomeScreen(api: widget.api, today: widget.today),
        1 => NoticeListScreen(api: widget.api),
        2 => CalendarScreen(api: widget.api, today: widget.today),
        3 => ScheduleListScreen(api: widget.api, today: widget.today),
        _ => MyTasksScreen(api: widget.api, today: widget.today),
      },
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: '홈',
          ),
          NavigationDestination(
            icon: Icon(Icons.campaign_outlined),
            selectedIcon: Icon(Icons.campaign),
            label: '공지',
          ),
          NavigationDestination(
            icon: Icon(Icons.calendar_month_outlined),
            selectedIcon: Icon(Icons.calendar_month),
            label: '캘린더',
          ),
          NavigationDestination(
            icon: Icon(Icons.event_note_outlined),
            selectedIcon: Icon(Icons.event_note),
            label: '일정',
          ),
          NavigationDestination(
            icon: Icon(Icons.checklist_outlined),
            selectedIcon: Icon(Icons.checklist),
            label: '내 할 일',
          ),
        ],
      ),
    );
  }
}
