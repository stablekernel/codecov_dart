@TestOn('vm')
library dart_codecov_generator.test.env_test;

import 'package:test/test.dart';

import '../bin/src/env.dart';

void main() {
  group('Environment', () {
    test('should default --html and --lcov to true', () {
      setupEnv([]);
      expect(env.html, isTrue);
      expect(env.lcov, isTrue);
    });
  });
}