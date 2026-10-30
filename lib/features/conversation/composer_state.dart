import 'package:dogcodes_app/l10n/strings.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import '../../core/host_hub.dart';
import '../../core/task_attachments.dart';
import '../../core/pc_api.dart' show uuid;
import '../../core/protocol.dart';
import '../../data/local_workspace.dart';
import 'agent_picker.dart';

/// One local draft scope. No network task is ever sent by restore or reconnect.
class ComposerState extends ChangeNotifier {
  ComposerState(this.hub) {
    prompt.addListener(_edited);
  }
  final HostHub hub;
  final prompt = TextEditingController();
  HostState? host;
  String? projectId, taskId, key, _bindingKey;
  AgentChoice? _choice;
  AgentChoice? get choice => _choice;
  set choice(AgentChoice? value) {
    _selection++;
    _choice = value;
    _edited();
  }

  List<TaskAttachment> attachments = [];
  bool restoring = false,
      uploading = false,
      picking = false,
      restoreFailed = false,
      _catalogLoading = false,
      _disposed = false,
      _hydrating = false;
  int _generation = 0, _uploadGeneration = 0, _selection = 0;
  String? activeAttachment, error;
  LocalWorkspace get store => hub.local;
  bool get hasContent =>
      prompt.text.trim().isNotEmpty || attachments.isNotEmpty;
  bool get choiceValid =>
      !restoreFailed &&
      choice != null &&
      host != null &&
      host!.executors.any((e) => sameExecutor(e, choice!.executor)) &&
      (choice!.model == null ||
          choice!.models.any((m) => m['id'] == choice!.model)) &&
      (choice!.thinking == null ||
          choice!.thinkingOptions.any((t) => t['id'] == choice!.thinking));

  Map<String, dynamic> _snapshot() => {
    'hostId': host?.id,
    'localBindingEpoch': ?host?.bindingEpoch,
    'projectId': projectId,
    'taskId': taskId,
    'text': prompt.text,
    'attachments': attachments.map((a) => a.toJson()).toList(),
    'choice': choice == null
        ? null
        : {
            'executor': choice!.executor,
            'catalog': choice!.catalog,
            'model': choice!.model,
            'thinking': choice!.thinking,
          },
  };
  Map<String, dynamic> get identity => {
    'key': key,
    'fingerprint': draftFingerprint(_snapshot()),
  };
  Future<void> flush() async {
    final scope = key;
    if (scope == null || restoring) return;
    if (restoreFailed) throw ProtocolException(tr("请先恢复原草稿，未覆盖本机记录。"));
    try {
      await store.saveDraft(scope, _snapshot());
    } catch (e) {
      if (!_disposed) {
        error = tr("草稿未能保存：{0}", [e]);
        notifyListeners();
      }
      rethrow;
    }
  }

  void _edited() {
    if (_hydrating || _disposed) return;
    unawaited(flush().catchError((Object _) {}));
    notifyListeners();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void setPicking(bool value) {
    picking = value;
    _notify();
  }

  Future<void> bind(
    HostState? h,
    String? project,
    String? task, {
    bool carry = false,
  }) async {
    final next = h == null || project == null
        ? null
        : draftKey(h.id, project, task, bindingEpoch: h.bindingEpoch);
    if (restoring && next == _bindingKey) return;
    if (!restoring && next == key && identical(host, h)) {
      ensureChoice();
      return;
    }
    final rebinding =
        host != null &&
        h != null &&
        host!.id == h.id &&
        host!.bindingEpoch != h.bindingEpoch;
    final discardSource =
        rebinding ||
        (h == null && host?.operations.retired == true) ||
        (host != null &&
            !hub.hosts.contains(host) &&
            host!.bindingEpoch != h?.bindingEpoch);
    final previous = carry && !discardSource ? _snapshot() : null;
    final savedPrevious = restoring || discardSource
        ? Future<void>.value()
        : flush();
    if (discardSource) {
      _hydrating = true;
      prompt.clear();
      attachments = [];
      _choice = null;
      _hydrating = false;
    }
    final generation = ++_generation;
    _bindingKey = next;
    restoring = true;
    _notify();
    try {
      await savedPrevious;
    } catch (_) {
      if (!_disposed && generation == _generation) {
        restoring = false;
        _notify();
      }
      rethrow;
    }
    if (_disposed || generation != _generation) return;
    _uploadGeneration++;
    host = h;
    projectId = project;
    taskId = task;
    key = next;
    restoring = true;
    restoreFailed = false;
    _hydrating = true;
    prompt.clear();
    attachments = [];
    _choice = null;
    error = null;
    _hydrating = false;
    _notify();
    try {
      final saved = next == null ? null : await store.draft(next);
      if (_disposed || generation != _generation) return;
      var data = saved;
      if (previous != null &&
          ((saved?['text'] ?? '') == '' &&
              (saved?['attachments'] as List? ?? []).isEmpty)) {
        final sameHost =
            previous['hostId'] == h?.id &&
            previous['localBindingEpoch'] == h?.bindingEpoch;
        data = {
          ...previous,
          'attachments': [
            for (final raw in previous['attachments'] as List)
              if (sameHost)
                raw
              else if (raw['blobId'] != null)
                {
                  ...raw as Map,
                  'reference': null,
                  'request': {...raw['request'] as Map, 'uploadId': uuid()},
                },
          ],
        };
      }
      if (data != null) {
        _hydrating = true;
        prompt.text = data['text'] as String? ?? '';
        attachments = [
          for (final a in data['attachments'] as List? ?? [])
            TaskAttachment.fromJson(a as Map),
        ];
        final c = data['choice'];
        if (c is Map) {
          _choice = AgentChoice(
            Map<String, dynamic>.from(c['executor'] as Map),
            catalog: c['catalog'] is Map
                ? Map<String, dynamic>.from(c['catalog'] as Map)
                : null,
            model: c['model'] as String?,
            thinking: c['thinking'] as String?,
          );
        }
        error = data['recoveryNote'] as String?;
        _hydrating = false;
      }
    } catch (e) {
      if (generation == _generation) {
        restoreFailed = true;
        error = tr("无法恢复草稿：{0}", [e]);
      }
    } finally {
      if (!_disposed && generation == _generation) {
        restoring = false;
        _hydrating = false;
        _notify();
        if (!restoreFailed) {
          await flush();
          await ensureChoice();
        }
      }
    }
  }

  Future<void> retryRestore() async {
    final h = host, project = projectId, task = taskId;
    key = null;
    restoreFailed = false;
    await bind(h, project, task);
  }

  Future<void> ensureChoice() async {
    final h = host, link = host?.link;
    if (_disposed ||
        restoring ||
        h == null ||
        !h.online ||
        link == null ||
        _catalogLoading) {
      return;
    }
    final executor = choice?.executor ?? defaultExecutor(h, h.task(taskId));
    if (executor == null) return;
    final generation = _generation, selection = _selection;
    _catalogLoading = true;
    try {
      final fresh = await loadChoice(link, executor, taskId);
      if (_disposed || generation != _generation || selection != _selection) {
        return;
      }
      _choice = AgentChoice(
        executor,
        catalog: fresh.catalog,
        model: choice?.model ?? fresh.model,
        thinking: choice?.thinking,
      );
      if (!choiceValid) error = tr("原 Agent、模型或思考强度当前不可用，请重新选择后发送。");
      await flush();
      _notify();
    } catch (e) {
      if (!_disposed && generation == _generation) {
        error = tr("暂时无法读取模型，可保留草稿后重试：{0}", [e]);
        _notify();
      }
    } finally {
      _catalogLoading = false;
      if (!_disposed && generation != _generation) unawaited(ensureChoice());
    }
  }

  Future<void> add(List<TaskAttachment> items) async {
    if (uploading || _disposed) return;
    try {
      validateAttachmentSelection([...attachments, ...items]);
    } catch (_) {
      await store.releaseUnusedAttachments(
        items.map((a) => a.blobId).whereType<String>(),
      );
      rethrow;
    }
    final target = attachments;
    target.addAll(items);
    error = null;
    try {
      await flush();
    } catch (_) {
      target.removeWhere((item) => items.contains(item));
      await store.releaseUnusedAttachments(
        items.map((item) => item.blobId).whereType<String>(),
      );
      rethrow;
    }
    _notify();
  }

  Future<void> remove(TaskAttachment item) async {
    if (uploading) return;
    attachments.remove(item);
    await flush();
    _notify();
    // Abort only the unfinished transfer, never the committed PC copy.
    if (host?.online == true) {
      try {
        await host!.link!.call('attachment_upload_abort', item.request);
      } catch (_) {
        /* The same identity remains harmless if the PC is unreachable. */
      }
    }
  }

  void pauseUploads() {
    _uploadGeneration++;
  }

  Future<List<Map<String, dynamic>>> prepareAttachments() async {
    if (uploading) throw ProtocolException(tr("附件仍在上传。"));
    final h = host, link = host?.link;
    if (h == null || link == null || !h.online) {
      throw ProtocolException(tr("电脑离线，附件及任务已保留为草稿。"));
    }
    validateAttachmentSelection(attachments);
    final generation = ++_uploadGeneration, epoch = h.connectionEpoch;
    uploading = true;
    error = null;
    _notify();
    try {
      await flush();
      for (final item in attachments) {
        activeAttachment = item.id;
        item.error = null;
        _notify();
        try {
          await AttachmentTransfer(store).upload(
            link,
            item,
            cancelled: () =>
                _disposed ||
                generation != _uploadGeneration ||
                host != h ||
                h.link != link ||
                h.connectionEpoch != epoch ||
                !h.online,
            checkpoint: () async {
              await flush();
              _notify();
            },
          );
        } catch (e) {
          item.error = '$e';
          rethrow;
        }
      }
      return attachments.map((a) => a.reference!).toList();
    } finally {
      uploading = false;
      activeAttachment = null;
      _notify();
    }
  }

  Future<void> submitted(Map<String, dynamic> original) async {
    await store.clearSubmittedDraft(original);
    if (original['key'] == key &&
        original['fingerprint'] == identity['fingerprint']) {
      _hydrating = true;
      prompt.clear();
      attachments = [];
      _hydrating = false;
      await flush();
      _notify();
    }
  }

  @override
  void dispose() {
    unawaited(flush().catchError((Object _) {}));
    _disposed = true;
    _generation++;
    _uploadGeneration++;
    prompt.removeListener(_edited);
    prompt.dispose();
    super.dispose();
  }
}
