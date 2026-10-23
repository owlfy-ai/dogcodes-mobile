import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'widget_test.dart' show FakeLink, fakeHub;

/// Bootstrap replies are released by the test, in any order.
class SlowLink extends FakeLink {
  SlowLink() : super('macbook-pro-host');
  final pending = <Completer<void>>[];
  bool hold = false;
  @override
  Future<dynamic> call(String method, dynamic params) async {
    if (method == 'bootstrap' && hold) {
      final gate = Completer<void>();
      pending.add(gate);
      await gate.future;
      final value = await super.call(method, params);
      // The earlier read predates the newest task.
      if (pending.indexOf(gate) == 0) (value['tasks'] as List).removeAt(0);
      return value;
    }
    return super.call(method, params);
  }
}

void main() {
  test('an earlier, slower refresh cannot overwrite a newer one', () async {
    final link = SlowLink();
    final hub = fakeHub(link);
    await hub.load(connect: false);
    final host = hub.hosts.single;
    await hub.attach(host, link);
    final tasks = (await link.call('bootstrap', null))['tasks'] as List;
    expect(tasks.length, greaterThanOrEqualTo(2));

    link.hold = true;
    final older = hub.refresh(host), newer = hub.refresh(host);
    await pumpEventQueue();
    expect(link.pending.length, 2);
    link.pending[1].complete();
    await newer;
    expect(host.tasks.length, tasks.length);
    link.pending[0].complete();
    await older;
    expect(host.tasks.length, tasks.length);
    hub.dispose();
  });
}
