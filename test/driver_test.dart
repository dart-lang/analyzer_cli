// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

@TestOn("vm")
library analyzer_cli.test.driver;

import 'dart:io';

import 'package:analyzer/plugin/options.dart';
import 'package:analyzer/source/analysis_options_provider.dart';
import 'package:analyzer/src/generated/engine.dart';
import 'package:analyzer/src/plugin/plugin_configuration.dart';
import 'package:analyzer/src/services/lint.dart';
import 'package:analyzer_cli/src/bootloader.dart';
import 'package:analyzer_cli/src/driver.dart';
import 'package:analyzer_cli/src/options.dart';
import 'package:path/path.dart' as path;
import 'package:plugin/plugin.dart';
import 'package:test/test.dart';
import 'package:yaml/src/yaml_node.dart';

main() {
  group('Driver', () {
    group('options', () {
      test('custom processor', () {
        Driver driver = new Driver();
        TestProcessor processor = new TestProcessor();
        driver.userDefinedPlugins = [new TestPlugin(processor)];
        driver.start([
          '--options',
          'test/data/test_options.yaml',
          'test/data/test_file.dart'
        ]);
        expect(processor.options['test_plugin'], isNotNull);
        expect(processor.exception, isNull);
      });
    });

    group('exit codes', () {
      int savedExitCode;
      ExitHandler savedExitHandler;
      setUp(() {
        savedExitCode = exitCode;
        savedExitHandler = exitHandler;
        exitHandler = (code) => exitCode = code;
      });
      tearDown(() {
        exitCode = savedExitCode;
        exitHandler = savedExitHandler;
      });

      test('fatal hints', () {
        Driver driver = new Driver();
        driver.start(['--fatal-hints', 'test/data/file_with_hint.dart']);
        expect(exitCode, 3);
      });

      test('not fatal hints', () {
        Driver driver = new Driver();
        driver.start(['test/data/file_with_hint.dart']);
        expect(exitCode, 0);
      });

      test('fatal errors', () {
        Driver driver = new Driver();
        driver.start(['test/data/file_with_error.dart']);
        expect(exitCode, 3);
      });

      test('not fatal warnings', () {
        Driver driver = new Driver();
        driver.start(['test/data/file_with_warning.dart']);
        expect(exitCode, 0);
      });

      test('fatal warnings', () {
        Driver driver = new Driver();
        driver.start(['--fatal-warnings', 'test/data/file_with_warning.dart']);
        expect(exitCode, 3);
      });

      test('missing options file', () {
        Driver driver = new Driver();
        driver.start([
          '--options',
          'test/data/NO_OPTIONS_HERE',
          'test/data/test_file.dart'
        ]);
        expect(exitCode, 3);
      });

      test('missing dart file', () {
        Driver driver = new Driver();
        driver.start(['test/data/NO_DART_FILE_HERE.dart']);
        expect(exitCode, 3);
      });
    });

    group('linter', () {
      group('lints in options', () {
        StringSink savedOutSink;
        Driver driver;

        setUp(() {
          savedOutSink = outSink;
          outSink = new StringBuffer();

          driver = new Driver();
          driver.start([
            '--options',
            'test/data/linter_project/.analysis_options',
            '--lints',
            'test/data/linter_project/test_file.dart'
          ]);
        });
        tearDown(() {
          outSink = savedOutSink;
        });

        test('gets analysis options', () {
          /// Lints should be enabled.
          expect(driver.context.analysisOptions.lint, isTrue);

          /// The .analysis_options file only specifies 'camel_case_types'.
          var lintNames = getLints(driver.context).map((r) => r.name);
          expect(lintNames, orderedEquals(['camel_case_types']));
        });

        test('generates lints', () {
          expect(outSink.toString(),
              contains('[lint] Name types using UpperCamelCase.'));
        });
      });

      group('default lints', () {
        StringSink savedOutSink;
        Driver driver;

        setUp(() {
          savedOutSink = outSink;
          outSink = new StringBuffer();

          driver = new Driver();
          driver.start(['--lints', 'test/data/linter_project/test_file.dart']);
        });
        tearDown(() {
          outSink = savedOutSink;
        });

        test('gets default lints', () {
          /// Lints should be enabled.
          expect(driver.context.analysisOptions.lint, isTrue);

          /// Default list should include camel_case_types.
          var lintNames = getLints(driver.context).map((r) => r.name);
          expect(lintNames, contains('camel_case_types'));
        });

        test('generates lints', () {
          expect(outSink.toString(),
              contains('[lint] Name types using UpperCamelCase.'));
        });
      });

      group('no `--lints` flag', () {
        StringSink savedOutSink;
        Driver driver;

        setUp(() {
          savedOutSink = outSink;
          outSink = new StringBuffer();

          driver = new Driver();
          driver.start(['test/data/linter_project/test_file.dart']);
        });
        tearDown(() {
          outSink = savedOutSink;
        });

        test('lints disabled', () {
          expect(driver.context.analysisOptions.lint, isFalse);
        });

        test('no registered lints', () {
          expect(getLints(driver.context), isEmpty);
        });

        test('no generated warnings', () {
          expect(outSink.toString(), contains('No issues found'));
        });
      });
    });

    test('containsLintRuleEntry', () {
      Map<String, YamlNode> options;
      options = parseOptions('''
linter:
  rules:
    - foo
        ''');
      expect(containsLintRuleEntry(options), true);
      options = parseOptions('''
        ''');
      expect(containsLintRuleEntry(options), false);
      options = parseOptions('''
linter:
  rules:
    # - foo
        ''');
      expect(containsLintRuleEntry(options), true);
      options = parseOptions('''
linter:
 # rules:
    # - foo
        ''');
      expect(containsLintRuleEntry(options), false);
    });

    group('in temp directory', () {
      StringSink savedOutSink, savedErrorSink;
      int savedExitCode;
      Directory savedCurrentDirectory;
      Directory tempDir;
      setUp(() {
        savedOutSink = outSink;
        savedErrorSink = errorSink;
        savedExitCode = exitCode;
        outSink = new StringBuffer();
        errorSink = new StringBuffer();
        savedCurrentDirectory = Directory.current;
        tempDir = Directory.systemTemp.createTempSync('analyzer_');
      });
      tearDown(() {
        outSink = savedOutSink;
        errorSink = savedErrorSink;
        exitCode = savedExitCode;
        Directory.current = savedCurrentDirectory;
        tempDir.deleteSync(recursive: true);
      });

      test('packages folder', () {
        Directory.current = tempDir;
        new File(path.join(tempDir.path, 'test.dart')).writeAsStringSync('''
import 'package:foo/bar.dart';
main() {
  baz();
}
        ''');
        Directory packagesDir =
            new Directory(path.join(tempDir.path, 'packages'));
        packagesDir.createSync();
        Directory fooDir = new Directory(path.join(packagesDir.path, 'foo'));
        fooDir.createSync();
        new File(path.join(fooDir.path, 'bar.dart')).writeAsStringSync('''
void baz() {}
        ''');
        new Driver().start(['test.dart']);
        expect(exitCode, 0);
      });

      test('no package resolution', () {
        Directory.current = tempDir;
        new File(path.join(tempDir.path, 'test.dart')).writeAsStringSync('''
import 'package:path/path.dart';
main() {}
        ''');
        new Driver().start(['test.dart']);
        expect(exitCode, 3);
        String stdout = outSink.toString();
        expect(stdout, contains('[error] Target of URI does not exist'));
        expect(stdout, contains('1 error found.'));
        expect(errorSink.toString(), '');
      });

      test('bad package root', () {
        new Driver().start(['--package-root', 'does/not/exist', 'test.dart']);
        String stdout = outSink.toString();
        expect(exitCode, 3);
        expect(
            stdout,
            contains(
                'Package root directory (does/not/exist) does not exist.'));
      });
    });
  });
  group('Bootloader', () {
    group('plugin processing', () {
      StringSink savedErrorSink;
      setUp(() {
        savedErrorSink = errorSink;
        errorSink = new StringBuffer();
      });
      tearDown(() {
        errorSink = savedErrorSink;
      });
      test('bad format', () {
        BootLoader loader = new BootLoader();
        loader.createImage([
          '--options',
          'test/data/bad_plugin_options.yaml',
          'test/data/test_file.dart'
        ]);
        expect(
            errorSink.toString(),
            equals('Plugin configuration skipped: Unrecognized plugin config '
                'format, expected `YamlMap`, got `YamlList` '
                '(line 2, column 4)\n'));
      });
      test('plugin config', () {
        BootLoader loader = new BootLoader();
        Image image = loader.createImage([
          '--options',
          'test/data/plugin_options.yaml',
          'test/data/test_file.dart'
        ]);
        var plugins = image.config.plugins;
        expect(plugins, hasLength(1));
        expect(plugins.first.name, equals('my_plugin1'));
      });
      group('plugin validation', () {
        test('requires class name', () {
          expect(
              validate(new PluginInfo(
                  name: 'test_plugin', libraryUri: 'my_package/foo.dart')),
              isNotNull);
        });
        test('requires library URI', () {
          expect(
              validate(
                  new PluginInfo(name: 'test_plugin', className: 'MyPlugin')),
              isNotNull);
        });
        test('check', () {
          expect(
              validate(new PluginInfo(
                  name: 'test_plugin',
                  className: 'MyPlugin',
                  libraryUri: 'my_package/foo.dart')),
              isNull);
        });
      });
    });
  });
}

Map<String, YamlNode> parseOptions(String src) =>
    new AnalysisOptionsProvider().getOptionsFromString(src);

class TestPlugin extends Plugin {
  TestProcessor processor;
  TestPlugin(this.processor);

  @override
  String get uniqueIdentifier => 'test_plugin.core';

  @override
  void registerExtensionPoints(RegisterExtensionPoint register) {
    // None
  }

  @override
  void registerExtensions(RegisterExtension register) {
    register(OPTIONS_PROCESSOR_EXTENSION_POINT_ID, processor);
  }
}

class TestProcessor extends OptionsProcessor {
  Map<String, YamlNode> options;
  Exception exception;

  @override
  void onError(Exception exception) {
    this.exception = exception;
  }

  @override
  void optionsProcessed(
      AnalysisContext context, Map<String, YamlNode> options) {
    this.options = options;
  }
}
