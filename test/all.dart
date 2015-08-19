// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'driver_test.dart' as driver;
import 'error_test.dart' as error;
import 'options_test.dart' as options;
import 'reporter_test.dart' as reporter;
import 'sdk_ext_test.dart' as sdk_ext;
import 'strong_mode_test.dart' as strong_mode;
import 'super_mixin_test.dart' as super_mixin;

main() {
  driver.main();
  error.main();
  options.main();
  reporter.main();
  sdk_ext.main();
  strong_mode.main();
  super_mixin.main();
}
