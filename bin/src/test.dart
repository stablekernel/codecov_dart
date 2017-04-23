// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

library dart_codecov_generator.bin.src.test;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';


const int _defaultObservatoryPort = 8444;

const String _observatoryFailPattern = 'Could not start Observatory HTTP server';
final RegExp _observatoryPortPattern = new RegExp(r'Observatory listening on http:\/\/127\.0\.0\.1:(\d+)');

const String _testsFailedPattern = 'Some tests failed.';
const String _testsPassedPattern = 'All tests passed!';


abstract class Test {
  static Future<Test> parse(String filePath) async {
    if (filePath.endsWith('.html')) {
      return new BrowserTest(filePath);
    } else if (await isDartFileBrowserOnly(filePath)) {
      return new BrowserTest(filePath);
    } else {
      return new VMTest(filePath);
    }
  }

  File dartTestFile;
  Process process;
  Test(String filePath) : dartTestFile = new File(filePath);
  Future<bool> run();
  void kill();
  void cleanUp() {}
}


class BrowserTest extends Test {
  File htmlTestFile;
  int observatoryPort;
  File _tempHtmlTestFile;
  BrowserTest(String filePath) : super(filePath);

  Future<bool> run() async {
    Logger log = new Logger('dcg');
    if (dartTestFile.path.endsWith('.html')) {
      htmlTestFile = dartTestFile;
    } else if (dartTestFile.path.endsWith('.dart')) {
      log.info('Generating .html file for ${dartTestFile.path}...');
      htmlTestFile = generateHtmlTestFile();
      _tempHtmlTestFile = htmlTestFile;
    }

    log.info('Running tests from ${dartTestFile.path} in content-shell...');
    process = await Process.start(
        'content_shell',
        [
          '--remote-debugging-port=$_defaultObservatoryPort',
          '--disable-extensions',
          '--disable-popup-blocking',
          '--bwsi',
          '--no-first-run',
          '--no-default-browser-check',
          '--disable-default-apps',
          '--disable-translate',
          htmlTestFile.path
        ],
        environment: {'DART_FLAGS': '--checked'}
    );

    bool observatoryFailed = false;
    Completer c = new Completer();
    process.stdout.transform(UTF8.decoder).transform(new LineSplitter()).listen((String line) {
      log.info(line);
      if (_observatoryPortPattern.hasMatch(line)) {
        Match m = _observatoryPortPattern.firstMatch(line);
        observatoryPort = int.parse(m.group(1));
      }
      if (line.contains(_observatoryFailPattern)) {
        observatoryFailed = true;
      }
      if (observatoryFailed && line.trim() == '') {
        log.severe('Observatory failed to start.');
        c.complete(false);
      }
    });
    process.stderr.transform(UTF8.decoder).transform(new LineSplitter()).listen((String line) {
      log.info(line);
      if (line.contains(_testsPassedPattern)) {
        log.info('Tests passed.');
        c.complete(true);
      }
      if (line.contains(_testsFailedPattern)) {
        log.severe('Tests failed.');
        c.complete(false);
      }
    });
    return c.future;
  }

  void kill() {
    process.kill();
  }

  void cleanUp() {
    if (_tempHtmlTestFile != null) {
      _tempHtmlTestFile.deleteSync();
    }
  }

  File generateHtmlTestFile() {
    File html = new File('${dartTestFile.path}.temp_html_test.html');
    html.createSync();
    String testPath = Uri.parse(dartTestFile.path).pathSegments.last;
    html.writeAsStringSync('<script type="application/dart" src="$testPath"></script>');
    return html;
  }
}


class VMTest extends Test {
  VMTest(String filePath) : super(filePath);

  Future<bool> run() async {
    Logger log = new Logger('dcg');
    log.info('Running tests in Dart VM...');
    process = await Process.start(
        'dart',
        ["--enable-vm-service=$_defaultObservatoryPort", "--pause-isolates-on-exit", "--warn-on-pause-with-no-debugger", dartTestFile.path],
//        ['--observe=$_defaultObservatoryPort', dartTestFile.path],
        environment: {'DART_FLAGS': '--checked'}
    );

    bool observatoryFailed = false;
    await for (String line in process.stdout.transform(UTF8.decoder).transform(new LineSplitter())) {
      log.info(line);
      if (line.contains(_observatoryFailPattern)) {
        observatoryFailed = true;
      }
      if (observatoryFailed && line.trim() == '') {
        log.severe('Observatory failed to start.');
        return false;
      }
      if (line.contains(_testsPassedPattern)) {
        log.info('Tests passed.');
        return true;
      }
      if (line.contains(_testsFailedPattern)) {
        log.severe('Tests failed.');
        return false;
      }
    }
    log.severe('Tests failed (unexpected error).');
    return false;
  }

  Future<Null> kill() async {
    process.kill();
  }
}


Future<int> getPidOfPort(int port) async {
  ProcessResult pr = await Process.run('lsof', ['-i', ':$port', '-t']);
  return int.parse((pr.stdout as String).replaceAll('\n', ''));
}

/// Taken from test_runner.dart and modified slightly.
Future<bool> isDartFileBrowserOnly(String dartFilePath) async {
  ProcessResult pr = await Process.run(
      'dart2js',
      ['--analyze-only', '--categories=Server', dartFilePath],
      runInShell: true
  );
  // TODO: When dart2js has fixed the issue with their exitcode we should
  //       rely on the exitcode instead of the stdout.
  return pr.stdout != null && (pr.stdout as String).contains('Error: Library not found');
}