import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import 'task_preview_screen.dart';

const contentMaxWidth = 720.0; // 넓은 화면(웹)에서 본문이 넘지 않을 폭

/// 본문 좌우 여백. 휴대폰 폭에서는 16 그대로, 넓은 화면에서는 본문을 [contentMaxWidth]로 가운데에 모음.
double contentInset(BuildContext context) {
  final side = (MediaQuery.sizeOf(context).width - contentMaxWidth) / 2;
  return side > 16 ? side : 16;
}

class NoticeListScreen extends StatefulWidget {
  const NoticeListScreen({super.key, required this.api});

  final ApiClient api;

  @override
  State<NoticeListScreen> createState() => _NoticeListScreenState();
}

class _NoticeListScreenState extends State<NoticeListScreen> {
  late Future<List<NoticeCard>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.api.fetchNotices();
  }

  Future<void> _reload() async {
    final future = widget.api.fetchNotices();
    setState(() {
      _future = future;
    });
    await future.catchError((_) => <NoticeCard>[]); // 오류는 FutureBuilder가 표시
  }

  Future<void> _openPreview(NoticeCard notice) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => TaskPreviewScreen(
          api: widget.api,
          noticeId: notice.id,
          link: notice.link,
        ),
      ),
    );
    if (saved != true || !mounted) return; // 저장하지 않고 나오면 카드는 그대로
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('할 일을 저장했어요')));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('공지'),
        actions: [
          if (kIsWeb) // 마우스로는 당겨서 새로고침이 안 됨
            IconButton(
              tooltip: '새로고침',
              onPressed: _reload,
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: FutureBuilder<List<NoticeCard>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return ErrorView(
              message: snapshot.error.toString(),
              onRetry: _reload,
            );
          }
          final notices = snapshot.data!;
          return RefreshIndicator(
            onRefresh: _reload,
            child: notices.isEmpty
                ? ListView(
                    children: const [
                      SizedBox(height: 120),
                      Center(child: Text('공지가 없습니다')),
                    ],
                  )
                : ListView.separated(
                    padding: EdgeInsets.symmetric(
                      horizontal: contentInset(context),
                      vertical: 16,
                    ),
                    itemCount: notices.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 12),
                    itemBuilder: (_, i) => NoticeCardView(
                      notice: notices[i],
                      onDoIt: () => _openPreview(notices[i]),
                    ),
                  ),
          );
        },
      ),
    );
  }
}

class NoticeCardView extends StatelessWidget {
  const NoticeCardView({
    super.key,
    required this.notice,
    required this.onDoIt,
    this.margin,
  });

  final NoticeCard notice;
  final VoidCallback onDoIt;
  final EdgeInsetsGeometry? margin; // 없으면 Card 기본 여백. 홈에서 다른 카드와 좌우를 맞출 때 지정

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final deadline = notice.nextDeadline;
    return Card(
      margin: margin,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${notice.board} · ${notice.published.length >= 10 ? notice.published.substring(0, 10) : notice.published}',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(notice.title, style: theme.textTheme.titleMedium),
            if (notice.summary != null) ...[
              const SizedBox(height: 6),
              Text(
                notice.summary!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ],
            if (deadline != null || notice.applyMethod != null) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  if (deadline != null)
                    InfoChip(
                      icon: Icons.event,
                      text: '${deadline.label} ${deadline.when}',
                    ),
                  if (notice.applyMethod != null)
                    InfoChip(icon: Icons.how_to_reg, text: notice.applyMethod!),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: !notice.analyzed
                  ? const FilledButton(onPressed: null, child: Text('분석 중'))
                  : notice.saved
                  ? OutlinedButton(
                      onPressed: onDoIt,
                      child: const Text('담은 할 일 보기'),
                    )
                  : FilledButton.icon(
                      onPressed: onDoIt,
                      icon: const Icon(Icons.add_task),
                      label: const Text('이거 할래'),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class InfoChip extends StatelessWidget {
  const InfoChip({
    super.key,
    required this.icon,
    required this.text,
    this.urgent = false,
  });

  final IconData icon;
  final String text;
  final bool urgent; // 마감 임박: 경고 색

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = urgent
        ? scheme.errorContainer
        : scheme.secondaryContainer;
    final foreground = urgent
        ? scheme.onErrorContainer
        : scheme.onSecondaryContainer;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: foreground),
          const SizedBox(width: 4),
          Flexible(
            child: Text(text, style: TextStyle(color: foreground)),
          ),
        ],
      ),
    );
  }
}

class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 40),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onRetry, child: const Text('다시 시도')),
          ],
        ),
      ),
    );
  }
}
