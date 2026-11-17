import 'package:flutter/material.dart';

import 'api.dart';
import 'screens/my_tasks_screen.dart';
import 'screens/notice_list_screen.dart';

void main() {
  runApp(MyApp(api: ApiClient()));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, required this.api, this.today});

  final ApiClient api;
  final DateTime? today; // 테스트용 '오늘' (D-day 계산)

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'notice',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      home: HomeShell(api: api, today: today),
    );
  }
}

/// 하단 탭: 공지 / 내 할 일. 탭을 바꿀 때마다 그 화면을 새로 불러옴 (다른 탭에서 저장·체크한 내용 반영).
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.api, this.today});

  final ApiClient api;
  final DateTime? today;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _index == 0
          ? NoticeListScreen(api: widget.api)
          : MyTasksScreen(api: widget.api, today: widget.today),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.campaign_outlined),
            selectedIcon: Icon(Icons.campaign),
            label: '공지',
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
