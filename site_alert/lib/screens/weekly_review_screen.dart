import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import 'my_tasks_screen.dart' show monthDay;
import 'notice_list_screen.dart' show ErrorView;

/// 주간 회고: 그 주(일~토)에 하기로 한 할 일의 완료율, 끝내지 못한 일, 회고 메모.
/// 처음엔 이번 주를 열고 ← → 로 지난 주를 오감 (이번 주보다 뒤로는 못 감).
class WeeklyReviewScreen extends StatefulWidget {
  const WeeklyReviewScreen({super.key, required this.api});

  final ApiClient api;

  @override
  State<WeeklyReviewScreen> createState() => _WeeklyReviewScreenState();
}

class _WeeklyReviewScreenState extends State<WeeklyReviewScreen> {
  WeeklyReview? _review;
  String? _error;
  String? _week; // 보고 있는 주의 일요일. null이면 이번 주 (서버가 정함)
  String? _thisWeek; // 이번 주 일요일 (처음 불러올 때 서버 응답에서)
  bool _saving = false;
  final _memo = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _memo.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _review = null;
      _error = null;
    });
    try {
      final review = await widget.api.fetchWeeklyReview(week: _week);
      if (!mounted) return;
      setState(() {
        _review = review;
        _week = review.weekStart;
        _thisWeek ??= review.weekStart;
        _memo.text = review.memo ?? '';
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  bool get _dirty =>
      _review != null && _memo.text.trim() != (_review!.memo ?? '');

  Future<void> _moveWeek(int days) async {
    if (_dirty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('저장하지 않은 메모가 있어요'),
          content: const Text('다른 주로 가면 쓴 내용이 사라져요.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('취소'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('이동'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    final start = DateTime.parse(_week!);
    _week = DateTime.utc(
      start.year,
      start.month,
      start.day + days,
    ).toIso8601String().substring(0, 10);
    _load();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final review = await widget.api.saveWeeklyReview(_week!, _memo.text);
      if (!mounted) return;
      setState(() {
        _review = review;
        _memo.text = review.memo ?? '';
      });
      _showMessage('저장했어요');
    } on ApiException catch (e) {
      if (mounted) _showMessage('저장하지 못했어요: ${e.message}'); // 쓴 내용은 그대로
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final review = _review;
    return Scaffold(
      appBar: AppBar(title: Text(_week == _thisWeek ? '이번 주 회고' : '주간 회고')),
      body: _error != null
          ? ErrorView(message: _error!, onRetry: _load)
          : review == null
          ? const Center(child: CircularProgressIndicator())
          : _buildContent(context, review),
    );
  }

  Widget _buildContent(BuildContext context, WeeklyReview review) {
    final theme = Theme.of(context);
    final isThisWeek = review.weekStart == _thisWeek;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          children: [
            IconButton(
              tooltip: '지난 주',
              onPressed: _saving ? null : () => _moveWeek(-7),
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Text(
                '${monthDay(review.weekStart)} ~ ${monthDay(review.weekEnd)}',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
            ),
            IconButton(
              tooltip: '다음 주',
              onPressed: _saving || isThisWeek ? null : () => _moveWeek(7),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: review.rate == null
                ? const Text('이 주에 하기로 한 할 일이 없어요')
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${review.planned}개 중 ${review.done}개 완료',
                              style: theme.textTheme.titleMedium,
                            ),
                          ),
                          Text(
                            '${(review.rate! * 100).round()}%',
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      LinearProgressIndicator(
                        value: review.rate,
                        minHeight: 8,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ],
                  ),
          ),
        ),
        if (review.planned > 0) ...[
          _heading(context, '끝내지 못한 일 ${review.unfinished.length}개'),
          if (review.unfinished.isEmpty) const Text('하기로 한 일을 모두 끝냈어요'),
          for (final t in review.unfinished)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                title: Text(t.title),
                subtitle: Text(
                  t.noticeTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: t.scheduledDate == null
                    ? null
                    : Text(monthDay(t.scheduledDate!)),
              ),
            ),
        ],
        _heading(context, '끝내지 못한 일과 그 이유'),
        TextField(
          controller: _memo,
          minLines: 4,
          maxLines: 8,
          maxLength: 2000,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: '예: 재학증명서 발급이 늦어져 신청서를 못 냈다',
          ),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _saving || !_dirty ? null : _save,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          child: _saving
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('저장'),
        ),
      ],
    );
  }

  Widget _heading(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 8),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleMedium
          ?.copyWith(fontWeight: FontWeight.bold),
    ),
  );
}
