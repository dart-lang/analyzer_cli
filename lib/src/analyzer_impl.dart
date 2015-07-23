// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library analyzer_cli.src.analyzer_impl;

import 'dart:collection';
import 'dart:io';

import 'package:analyzer/src/generated/element.dart';
import 'package:analyzer/src/generated/engine.dart';
import 'package:analyzer/src/generated/error.dart';
import 'package:analyzer/src/generated/java_engine.dart';
import 'package:analyzer/src/generated/java_io.dart';
import 'package:analyzer/src/generated/sdk_io.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:analyzer/src/generated/source_io.dart';
import 'package:analyzer/src/generated/utilities_general.dart';
import 'package:analyzer_cli/src/driver.dart';
import 'package:analyzer_cli/src/error_formatter.dart';
import 'package:analyzer_cli/src/lint.dart';
import 'package:analyzer_cli/src/options.dart';
import 'package:dev_compiler/strong_mode.dart' show StrongChecker;

DirectoryBasedDartSdk sdk;

/// The maximum number of sources for which AST structures should be kept in the cache.
const int _maxCacheSize = 512;

int currentTimeMillis() => new DateTime.now().millisecondsSinceEpoch;

/// Analyzes single library [File].
class AnalyzerImpl {
  final CommandLineOptions options;
  final int startTime;

  final AnalysisContext context;
  final StrongChecker strongChecker;
  final Source librarySource;
  /// All [Source]s references by the analyzed library.
  final Set<Source> sources = new Set<Source>();

  /// All [AnalysisErrorInfo]s in the analyzed library.
  final List<AnalysisErrorInfo> errorInfos = new List<AnalysisErrorInfo>();

  /// [HashMap] between sources and analysis error infos.
  final HashMap<Source, AnalysisErrorInfo> sourceErrorsMap =
      new HashMap<Source, AnalysisErrorInfo>();

  /// If the file specified on the command line is part of a package, the name
  /// of that package.  Otherwise `null`.  This allows us to analyze the file
  /// specified on the command line as though it is reached via a "package:"
  /// URI, but avoid suppressing its output in the event that the user has not
  /// specified the "--package-warnings" option.
  String _selfPackageName;

  AnalyzerImpl(this.context, this.strongChecker, this.librarySource,
      this.options, this.startTime);

  /// Returns the maximal [ErrorSeverity] of the recorded errors.
  ErrorSeverity get maxErrorSeverity {
    var status = ErrorSeverity.NONE;
    for (AnalysisErrorInfo errorInfo in errorInfos) {
      for (AnalysisError error in errorInfo.errors) {
        if (!_isDesiredError(error)) {
          continue;
        }
        var severity = computeSeverity(error, options.enableTypeChecks);
        status = status.max(severity);
      }
    }
    return status;
  }

  void addCompilationUnitSource(CompilationUnitElement unit,
      Set<LibraryElement> libraries, Set<CompilationUnitElement> units) {
    if (unit == null || units.contains(unit)) {
      return;
    }
    units.add(unit);
    sources.add(unit.source);
  }

  void addLibrarySources(LibraryElement library, Set<LibraryElement> libraries,
      Set<CompilationUnitElement> units) {
    if (library == null || !libraries.add(library)) {
      return;
    }
    // Maybe skip library.
    {
      UriKind uriKind = library.source.uriKind;
      // Optionally skip package: libraries.
      if (!options.showPackageWarnings && _isOtherPackage(library.source.uri)) {
        return;
      }
      // Optionally skip SDK libraries.
      if (!options.showSdkWarnings && uriKind == UriKind.DART_URI) {
        return;
      }
    }
    // Add compilation units.
    addCompilationUnitSource(library.definingCompilationUnit, libraries, units);
    for (CompilationUnitElement child in library.parts) {
      addCompilationUnitSource(child, libraries, units);
    }
    // Add referenced libraries.
    for (LibraryElement child in library.importedLibraries) {
      addLibrarySources(child, libraries, units);
    }
    for (LibraryElement child in library.exportedLibraries) {
      addLibrarySources(child, libraries, units);
    }
  }

  /// Treats the [sourcePath] as the top level library and analyzes it using a
  /// synchronous algorithm over the analysis engine. If [printMode] is `0`,
  /// then no error or performance information is printed. If [printMode] is `1`,
  /// then both will be printed. If [printMode] is `2`, then only performance
  /// information will be printed, and it will be marked as being for a cold VM.
  ErrorSeverity analyzeSync({int printMode: 1}) {
    setupForAnalysis();
    return _analyzeSync(printMode);
  }

  /// Fills [errorInfos] using [sources].
  void prepareErrors() {
    for (Source source in sources) {
      context.computeErrors(source);

      var sourceErrors = context.getErrors(source);
      errorInfos.add(sourceErrors);

      if (options.strongMode) {
        errorInfos.add(strongChecker.computeErrors(source));
      }
    }
  }

  /// Fills [sources].
  void prepareSources(LibraryElement library) {
    var units = new Set<CompilationUnitElement>();
    var libraries = new Set<LibraryElement>();
    addLibrarySources(library, libraries, units);
  }

  /// Setup local fields such as the analysis context for analysis.
  void setupForAnalysis() {
    sources.clear();
    errorInfos.clear();
    // Register lints.
    if (options.lints) {
      registerLints();
    }
    Uri libraryUri = librarySource.uri;
    if (libraryUri.scheme == 'package' && libraryUri.pathSegments.length > 0) {
      _selfPackageName = libraryUri.pathSegments[0];
    }
  }

  /// The sync version of analysis.
  ErrorSeverity _analyzeSync(int printMode) {
    // Don't try to analyze parts.
    if (context.computeKindOf(librarySource) == SourceKind.PART) {
      print("Only libraries can be analyzed.");
      print("${librarySource.fullName} is a part and can not be analyzed.");
      return ErrorSeverity.ERROR;
    }
    // Resolve library.
    var libraryElement = context.computeLibraryElement(librarySource);
    // Prepare source and errors.
    prepareSources(libraryElement);
    prepareErrors();

    // Print errors and performance numbers.
    if (printMode == 1) {
      _printErrorsAndPerf();
    } else if (printMode == 2) {
      _printColdPerf();
    }

    // Compute max severity and set exitCode.
    ErrorSeverity status = maxErrorSeverity;
    if (status == ErrorSeverity.WARNING && options.warningsAreFatal) {
      status = ErrorSeverity.ERROR;
    }
    return status;
  }

  bool _isDesiredError(AnalysisError error) {
    if (error.errorCode.type == ErrorType.TODO) {
      return false;
    }
    if (computeSeverity(error, options.enableTypeChecks) ==
            ErrorSeverity.INFO &&
        options.disableHints) {
      return false;
    }
    return true;
  }

  /// Determine whether the given URI refers to a package other than the package
  /// being analyzed.
  bool _isOtherPackage(Uri uri) {
    if (uri.scheme != 'package') {
      return false;
    }
    if (_selfPackageName != null &&
        uri.pathSegments.length > 0 &&
        uri.pathSegments[0] == _selfPackageName) {
      return false;
    }
    return true;
  }

  _printColdPerf() {
    // Print cold VM performance numbers.
    int totalTime = currentTimeMillis() - startTime;
    int otherTime = totalTime;
    for (PerformanceTag tag in PerformanceTag.all) {
      if (tag != PerformanceTag.UNKNOWN) {
        int tagTime = tag.elapsedMs;
        outSink.writeln('${tag.label}-cold:$tagTime');
        otherTime -= tagTime;
      }
    }
    outSink.writeln('other-cold:$otherTime');
    outSink.writeln("total-cold:$totalTime");
  }

  _printErrorsAndPerf() {
    // The following is a hack. We currently print out to stderr to ensure that
    // when in batch mode we print to stderr, this is because the prints from
    // batch are made to stderr. The reason that options.shouldBatch isn't used
    // is because when the argument flags are constructed in BatchRunner and
    // passed in from batch mode which removes the batch flag to prevent the
    // "cannot have the batch flag and source file" error message.
    StringSink sink = options.machineFormat ? errorSink : outSink;

    // Print errors.
    ErrorFormatter formatter =
        new ErrorFormatter(sink, options, _isDesiredError);
    formatter.formatErrors(errorInfos);
  }

  /// Compute the severity of the error; however, if
  /// [enableTypeChecks] is false, then de-escalate checked-mode compile time
  /// errors to a severity of [ErrorSeverity.INFO].
  static ErrorSeverity computeSeverity(
      AnalysisError error, bool enableTypeChecks) {
    if (!enableTypeChecks &&
        error.errorCode.type == ErrorType.CHECKED_MODE_COMPILE_TIME_ERROR) {
      return ErrorSeverity.INFO;
    }
    return error.errorCode.errorSeverity;
  }

  /// Return the corresponding package directory or `null` if none is found.
  static JavaFile getPackageDirectoryFor(JavaFile sourceFile) {
    // We are going to ask parent file, so get absolute path.
    sourceFile = sourceFile.getAbsoluteFile();
    // Look in the containing directories.
    JavaFile dir = sourceFile.getParentFile();
    while (dir != null) {
      JavaFile packagesDir = new JavaFile.relative(dir, "packages");
      if (packagesDir.exists()) {
        return packagesDir;
      }
      dir = dir.getParentFile();
    }
    // Not found.
    return null;
  }
}

/// This [Logger] prints out information comments to [outSink] and error messages
/// to [errorSink].
class StdLogger extends Logger {
  StdLogger();

  @override
  void logError(String message, [CaughtException exception]) {
    errorSink.writeln(message);
    if (exception != null) {
      errorSink.writeln(exception);
    }
  }

  @override
  void logError2(String message, Object exception) {
    errorSink.writeln(message);
    if (exception != null) {
      errorSink.writeln(exception.toString());
    }
  }

  @override
  void logInformation(String message, [CaughtException exception]) {
    outSink.writeln(message);
    if (exception != null) {
      outSink.writeln(exception);
    }
  }

  @override
  void logInformation2(String message, Object exception) {
    outSink.writeln(message);
    if (exception != null) {
      outSink.writeln(exception.toString());
    }
  }
}
