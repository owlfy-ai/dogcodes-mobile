import 'package:dogcodes_app/l10n/strings.dart';
import 'package:flutter/material.dart';
import '../../core/history_search.dart';
import '../../core/host_hub.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../conversation/conversation_page.dart';

class HistorySearchPage extends StatefulWidget {
  const HistorySearchPage({
    super.key,
    required this.sessions,
    this.initialQuery = '',
  });
  final List<SessionRef> sessions;
  final String initialQuery;
  @override
  State<HistorySearchPage> createState() => _HistorySearchPageState();
}

class _HistorySearchPageState extends State<HistorySearchPage> {
  late final search = HistorySearch(widget.sessions);
  late final text = TextEditingController(text: widget.initialQuery);
  String? error;
  @override
  void initState() {
    super.initState();
    if (text.text.isNotEmpty) _search();
  }

  Future<void> _search() async {
    setState(() => error = null);
    try {
      await search.search(text.text);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  @override
  void dispose() {
    search.dispose();
    text.dispose();
    super.dispose();
  }

  void _record(HistoryMatches group, Map<String, dynamic> item) {
    final s = group.session;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (d) => FractionallySizedBox(
        heightFactor: .8,
        child: Padding(
          padding: const EdgeInsets.all(DcSpace.page),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(s.title, style: Theme.of(context).textTheme.titleMedium),
              Text(
                '${s.projectName} · ${s.host.placeName(s.project)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Expanded(
                child: SingleChildScrollView(
                  child: SelectableText('${item['text'] ?? ''}'),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () {
                  Navigator.pop(d);
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ConversationPage(
                        hostId: s.host.id,
                        taskId: s.taskId,
                        focusTurnId: item['turnId'] as String?,
                      ),
                    ),
                  );
                },
                child: Text(tr("打开对应会话")),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    watchAppLanguage(context);
    return Scaffold(
      appBar: DetailBar(
        title: tr("搜索历史"),
        subtitle: tr("{0} 个会话 · 按当前电脑和项目范围", [widget.sessions.length]),
      ),
      body: ListenableBuilder(
        listenable: search,
        builder: (context, _) {
          final groups = search.groups.where(
            (g) => g.items.isNotEmpty || g.error != null || g.next != null,
          );
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: DcSpace.page),
                child: TextField(
                  controller: text,
                  autofocus: widget.initialQuery.isEmpty,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                  decoration: InputDecoration(
                    hintText: tr("搜索已保存的消息正文"),
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: IconButton(
                      tooltip: tr("搜索历史正文"),
                      onPressed: _search,
                      icon: const Icon(Icons.arrow_forward),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: EdgeInsets.all(12),
                child: Text(tr("在电脑上检索已保存的对话正文，不包含思考过程或附件内容。")),
              ),
              if (error != null) InlineNotice(error!, danger: true),
              if (search.query.isNotEmpty && search.offlineHosts.isNotEmpty)
                InlineNotice(
                  tr("{0} 离线，未搜索其中的会话；连接后重新搜索。", [
                    search.offlineHosts.join('、'),
                  ]),
                ),
              if (search.searching) const LinearProgressIndicator(minHeight: 2),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [
                    if (!search.searching && groups.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          search.query.isEmpty
                              ? tr("输入关键词开始搜索")
                              : tr("没有找到匹配的历史记录"),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    for (final group in groups) ...[
                      SectionLabel(group.session.title),
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: DcSpace.page,
                        ),
                        child: Text(
                          '${group.session.projectName} · ${group.session.host.placeName(group.session.project)}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                      for (final item in group.items)
                        ListTile(
                          title: Text(
                            '${item['text'] ?? ''}',
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${item['kind'] == 'user_message'
                                ? tr("你")
                                : item['kind'] == 'assistant_message'
                                ? 'Agent'
                                : tr("记录")} · ${_time(item['occurredAt'])}',
                          ),
                          onTap: () => _record(group, item),
                        ),
                      if (group.error != null)
                        InlineNotice(group.error!, danger: true),
                      if (group.next != null || group.error != null)
                        TextButton(
                          onPressed: group.busy
                              ? null
                              : () => search.more(group),
                          child: Text(
                            group.busy
                                ? tr("查询中…")
                                : group.error == null
                                ? tr("加载更多记录")
                                : tr("重试此会话"),
                          ),
                        ),
                    ],
                    if (!search.searching && search.remaining > 0)
                      Padding(
                        padding: const EdgeInsets.all(DcSpace.page),
                        child: OutlinedButton(
                          onPressed: search.searchMore,
                          child: Text(
                            tr("继续搜索更早的 {0} 个会话", [search.remaining]),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  String _time(Object? value) {
    final time = value is num
        ? DateTime.fromMillisecondsSinceEpoch(value.toInt())
        : DateTime.tryParse('$value');
    return time == null ? '' : '${time.toLocal()}'.split('.').first;
  }
}
