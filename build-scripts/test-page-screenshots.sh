#!/bin/bash
set -euo pipefail
capture_root="$(cd "$(dirname "$0")/.." && pwd)"
capture_build="$capture_root/build/PageScreenshotHarness"
mkdir -p "$capture_build"
python3 - "$capture_root" "$capture_build" <<'PY'
from pathlib import Path
import shutil, sys
root, build = map(Path, sys.argv[1:3])
(build/'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ScreenshotHarness", platforms: [.macOS(.v15)], targets: [
.target(name: "Phi", swiftSettings: [.swiftLanguageMode(.v5), .unsafeFlags(["-enable-testing"])]),
.testTarget(name: "ScreenshotTests", dependencies: ["Phi"], swiftSettings: [.swiftLanguageMode(.v5)]),
.executableTarget(name: "ScreenshotFixture", dependencies: ["Phi"], swiftSettings: [.swiftLanguageMode(.v5)])])
''')
for path in [build/'Sources', build/'Tests']:
    if path.exists(): shutil.rmtree(path)
source=build/'Sources/Phi'; source.mkdir(parents=True)
fixture=build/'Sources/ScreenshotFixture'; fixture.mkdir(parents=True)
tests=build/'Tests/ScreenshotTests'; tests.mkdir(parents=True)
for name in ['Sources/States/PageScreenshotService.swift','Sources/States/PageScreenshotGeometry.swift','Sources/UserInterface/WebContent/Header/PageScreenshotRegionSelector.swift','Tests/PageScreenshotHarness/Dependencies.swift']:
    shutil.copy(root/name, source/Path(name).name)
for file in (root/'Sources/UserInterface/PageScreenshot').glob('*.swift'):
    shutil.copy(file,source/file.name)
shutil.copy(root/'Tests/PageScreenshotHarness/Fixture.swift',fixture/'Fixture.swift')
for name in ['PageScreenshotServiceTests','PageScreenshotGeometryTests','PageScreenshotRegionSelectorTests','ScreenshotEditorTests','ScreenshotEditorInteractionTests','ScreenshotCropTests']:
    shutil.copy(root/f'Tests/PhiBrowserTests/{name}.swift',tests/f'{name}.swift')
PY
if [[ "${1:-}" == "--fixture" || "${1:-}" == "--render" ]]; then
    swift build --package-path "$capture_build" --product ScreenshotFixture
    capture_binary_dir="$(swift build --package-path "$capture_build" --show-bin-path)"
    capture_app="$capture_build/Phi Screenshot Editor.app"
    mkdir -p "$capture_app/Contents/MacOS" "$capture_app/Contents/Resources"
    cp "$capture_root/Resources/ThirdParty/ItsPaint-LICENSE.txt" "$capture_app/Contents/Resources/ItsPaint-LICENSE.txt"
    cp "$capture_binary_dir/ScreenshotFixture" "$capture_app/Contents/MacOS/ScreenshotFixture"
    cat > "$capture_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.phibrowser.screenshot.fixture</string>
<key>CFBundleName</key><string>Phi Screenshot Editor</string>
<key>CFBundleExecutable</key><string>ScreenshotFixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>ScreenshotFixtureApplication</string>
</dict></plist>
PLIST
    if [[ "${1:-}" == "--render" ]]; then
        "$capture_app/Contents/MacOS/ScreenshotFixture" --render "$capture_build/evidence"
    else
        open -n "$capture_app"
    fi
    echo "$capture_app"
else
    swift test --package-path "$capture_build" "$@"
fi
