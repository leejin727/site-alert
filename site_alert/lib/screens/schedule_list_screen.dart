import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import 'my_tasks_screen.dart' show daysLeft, monthDay, urgentDays;
import 'notice_list_screen.dart' show ErrorView, InfoChip, contentInset;
import 'schedule_detail_screen.dart';
import 'schedule_form_screen.dart';
import 'task_preview_screen.dart' show Tag;

/// 일정: 직접 만든 일정(시험·공모전)과 공지에서 담은 것을 함께.
/// 다가오는 것이 가까운 순으로 위, 지난 것은 아래 (정렬은 서버가 함).
class ScheduleListScreen extends StatefulWidget {
  const ScheduleListScreen({super.key, required this.api, this.today});

  final ApiClient api;
  final DateTime? today; // 테스트용. 없으면 기기의 오늘 날짜

  @override
  State<ScheduleListScreen> createState() => _ScheduleListScreenState();
}

class _ScheduleListScreenState extends State<ScheduleListScreen> {
  List<ScheduleEntry>? _entries;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final entries = await widget.api.fetchSchedules();
      if (mounted) setState(() => _entries = entries);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _open(ScheduleEntry entry) async {
    await openSource(context, widget.api, entry.source, today: widget.today);
    if (mounted) _load();
  }

  Future<void> _create() async {
    final created = await Navigator.of(context).push<ScheduleDetail>(
      MaterialPageRoute(
        builder: (_) =>
            ScheduleFormScreen(api: widget.api, today: widget.today),
      ),
    );
    if (!mounted) return;
    if (created != null) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ScheduleDetailScreen(
            api: widget.api,
            scheduleId: created.id,
            initial: created,
            today: widget.today,
          ),
        ),
      );
    }
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    return Scaffold(
      appBar: AppBar(
        title: const Text('일정'),
        actions: [
          if (kIsWeb) // 마우스로는 당겨서 새로고침이 안 됨
            IconButton(
              tooltip: '새로고침',
              onPressed: _load,
              icon: const Icon(Icons.refresh),
            ),
          TextButton.icon(
            onPressed: _create,
            icon: const Icon(Icons.add),
            label: const Text('일정 추가'),
          ),
        ],
      ),
      body: _error != null
          ? ErrorView(message: _error!, onRetry: _load)
          : entries == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(onRefresh: _load, child: _buildList(entries)),
    );
  }

  Widget _buildList(List<ScheduleEntry> entries) {
    if (entries.isEmpty) {
      return ListView(
        children: const [
          SizedBox(height: 120),
          Center(
            child: Text(
              "일정이 없어요.\n시험·공모전을 추가하거나 공지에서 '이거 할래'를 눌러 담아 보세요.",
              textAlign: TextAlign.center,
            ),
          ),
        ],
      );
    }
    final today = widget.today ?? DateTime.now();
    return ListView(
      padding: EdgeInsets.symmetric(
        horizontal: contentInset(context),
        vertical: 16,
      ),
      children: [
        for (final e in entries)
          ScheduleEntryCard(entry: e, today: today, onTap: () => _open(e)),
      ],
    );
  }
}

class ScheduleEntryCard extends StatelessWidget {
  const ScheduleEntryCard({
    super.key,
    required this.entry,
    required this.today,
    required this.onTap,
  });

  final ScheduleEntry entry;
  final DateTime today;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final days = entry.date == null ? null : daysLeft(entry.date!, today);
    final past = days != null && days < 0;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Tag(kindLabel(entry.source.kind)), // 출처: 공지 / 시험 / 공모전
              const SizedBox(height: 6),
              Text(
                entry.source.title,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: past ? theme.colorScheme.onSurfaceVariant : null,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  InfoChip(
                    icon: Icons.event,
                    urgent: days != null && days >= 0 && days <= urgentDays,
                    text: days == null
                        ? '날짜 미정'
                        : '${scheduleDday(days)} · ${monthDay(entry.date!)}',
                  ),
                  InfoChip(
                    icon: Icons.checklist,
                    text: entry.total == 0
                        ? '할 일 없음'
                        : '${entry.done}/${entry.total} 완료',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
