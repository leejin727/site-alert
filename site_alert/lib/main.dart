import 'package:flutter/material.dart';

import 'api.dart';
import 'floating_tab_bar.dart';
import 'screens/calendar_screen.dart';
import 'screens/home_screen.dart';
import 'screens/my_tasks_screen.dart';
import 'screens/notice_list_screen.dart';
import 'screens/schedule_list_screen.dart';
import 'theme.dart';

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
      theme: buildAppTheme(),
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
      bottomNavigationBar: FloatingTabBar(
        selectedIndex: _index,
        onSelected: (i) => setState(() => _index = i),
        items: const [
          TabItem(
            icon: Icons.home_outlined,
            selectedIcon: Icons.home,
            label: '홈',
          ),
          TabItem(
            icon: Icons.campaign_outlined,
            selectedIcon: Icons.campaign,
            label: '공지',
          ),
          TabItem(
            icon: Icons.calendar_month_outlined,
            selectedIcon: Icons.calendar_month,
            label: '캘린더',
          ),
          TabItem(
            icon: Icons.event_note_outlined,
            selectedIcon: Icons.event_note,
            label: '일정',
          ),
          TabItem(
            icon: Icons.checklist_outlined,
            selectedIcon: Icons.checklist,
            label: '내 할 일',
          ),
        ],
      ),
    );
  }
}
