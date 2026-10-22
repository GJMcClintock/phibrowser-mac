#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/phi-shortcuts.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
python3 - "$task_root" "$task_build" <<'PY'
from pathlib import Path
import re
import sys
root, output = map(Path, sys.argv[1:])
classes = ['ShortcutConfigurationTests', 'ShortcutInventoryTests']
count = sum(len(re.findall(r'^    func test\w+\(', (root / 'Tests/PhiBrowserTests' / (name + '.swift')).read_text(), re.M)) for name in classes)
assert count > 0
(output / 'main.swift').write_text('''import XCTest
import Foundation
let suite = XCTestSuite(name: "Shortcut model tests")
''' + '\n'.join('suite.addTest(' + name + '.defaultTestSuite)' for name in classes) + '''
suite.run()
guard let result = suite.testRun else { fatalError("XCTest did not run") }
print("Executed \\(result.executionCount) tests; \\(result.totalFailureCount) failures")
exit(result.executionCount == ''' + str(count) + ''' && result.totalFailureCount == 0 ? 0 : 1)
''')
PY
task_xcode_frameworks="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
task_xcode_libraries="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/usr/lib"
xcrun swiftc -swift-version 5 -D SHORTCUTS_HOSTLESS_TESTS \
  -F "$task_xcode_frameworks" -Xlinker -rpath -Xlinker "$task_xcode_frameworks" \
  -I "$task_xcode_libraries" -L "$task_xcode_libraries" -lXCTestSwiftSupport \
  -Xlinker -rpath -Xlinker "$task_xcode_libraries" \
  -module-cache-path "$task_build/modules" \
  "$task_root/Sources/UserInterface/Preferences/Shortcuts/Shortcuts.swift" \
  "$task_root/Sources/UserInterface/Preferences/Shortcuts/ShortcutConfiguration.swift" \
  "$task_root/Sources/UserInterface/Preferences/Shortcuts/ShortcutInventory.swift" \
  "$task_root/Tests/PhiBrowserTests/ShortcutConfigurationTests.swift" \
  "$task_root/Tests/PhiBrowserTests/ShortcutInventoryTests.swift" \
  "$task_build/main.swift" -o "$task_build/tests"
"$task_build/tests" "$@"
