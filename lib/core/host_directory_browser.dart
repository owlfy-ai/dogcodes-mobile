import 'package:flutter/foundation.dart';
import 'host_hub.dart';
import 'pc_api.dart';
import 'protocol.dart';

/// Paths (including Windows drives and parents) are returned by the PC.
/// The phone never interprets them using its own filesystem or joins paths.
class HostDirectoryBrowser extends ChangeNotifier {
  HostDirectoryBrowser(this.host);
  final HostState host;
  String? path, parent, error;
  List<Map<String, dynamic>> entries = [];
  int? next;
  bool loading = false, loadingMore = false, loaded = false, _disposed = false;

  /// Hidden directories are listed only after the user asks for them.
  bool showHidden = false;
  int _generation = 0;
  String? _requestedPath;
  bool get selectable => loaded && path != null && !loading && error == null;

  Future<void> open(String? target) async {
    final generation = ++_generation;
    _requestedPath = target;
    loading = true;
    loadingMore = false;
    error = null;
    notifyListeners();
    await _read(target, 0, generation, append: false);
  }

  Future<void> retry() => open(_requestedPath);
  Future<void> setShowHidden(bool value) async {
    if (value == showHidden) return;
    showHidden = value;
    await open(path ?? _requestedPath);
  }

  Future<void> more() async {
    final offset = next;
    if (loading || loadingMore || offset == null) return;
    loadingMore = true;
    error = null;
    notifyListeners();
    await _read(path, offset, _generation, append: true);
  }

  Future<void> _read(
    String? target,
    int offset,
    int generation, {
    required bool append,
  }) async {
    final link = host.link, epoch = host.connectionEpoch;
    try {
      if (!host.online || link == null) {
        throw const ProtocolException('电脑离线，重新连接后再浏览目录。');
      }
      final value = await link.hostDirectories(
        target,
        offset: offset,
        showHidden: showHidden,
      );
      if (_disposed || generation != _generation) return;
      if (host.link != link || host.connectionEpoch != epoch || !host.online) {
        throw const ProtocolException('连接已更换，请重新读取目录。');
      }
      if (value['entries'] is! List ||
          (target != null && value['path'] is! String) ||
          (append && value['path'] != path)) {
        throw const ProtocolException('电脑未返回有效的目录列表，请更新电脑端后重试。');
      }
      final after = (value['next'] as num?)?.toInt();
      if (after != null && after <= offset) {
        throw const ProtocolException('目录分页没有前进，请刷新目录。');
      }
      final list = [
        for (final e in value['entries'] as List)
          if (e is Map && e['name'] is String && e['path'] is String)
            Map<String, dynamic>.from(e),
      ];
      if (append) {
        final known = entries.map((e) => e['path']).toSet();
        entries.addAll(list.where((e) => known.add(e['path'])));
      } else {
        path = value['path'] as String?;
        parent = value['parent'] as String?;
        entries = list;
      }
      next = after;
      loaded = true;
    } catch (e) {
      if (!_disposed && generation == _generation) {
        error =
            e is ProtocolException &&
                e.message.contains('remote method unavailable')
            ? '电脑端暂不支持目录选择，请更新电脑端后重试。'
            : '$e';
      }
    } finally {
      if (!_disposed && generation == _generation) {
        loading = false;
        loadingMore = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
