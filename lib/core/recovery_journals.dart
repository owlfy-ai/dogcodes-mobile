part of 'mobile_operations.dart';

final _recoveryJournalTails = Expando<Future<void>>('recovery-journals');

extension RecoveryJournals on MobileOperations {
  Future<void> forgetRecoveryJournals() {
    _journalsForgotten = true;
    return _journalSerial(() async {
      final store = storage;
      for (final item in [key, '$key.side', _cancelKey, _stopsKey]) {
        if (store is ErasableSecretStorage) {
          await store.delete(item);
        } else {
          await store.write(item, 'null');
        }
      }
    });
  }

  Future<T> _journalSerial<T>(Future<T> Function() action) {
    final previous = _recoveryJournalTails[storage] ?? Future<void>.value(),
        gate = Completer<void>();
    _recoveryJournalTails[storage] = gate.future;
    return () async {
      await previous;
      try {
        return await action();
      } finally {
        // Do not retain an idle Future from a completed caller's async zone.
        // A queued writer owns the tail until its own action has completed.
        if (identical(_recoveryJournalTails[storage], gate.future)) {
          _recoveryJournalTails[storage] = null;
        }
        gate.complete();
      }
    }();
  }
}
