import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dogcodes_app/ui/theme.dart';

void main() {
  test('a resting pointer never tints rows like a selection', () {
    for (final b in Brightness.values) {
      expect(dcTheme(b).hoverColor, Colors.transparent);
    }
  });
}
