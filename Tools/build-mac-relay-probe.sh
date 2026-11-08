#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
out=${1:-/private/tmp/NeuralRelayProbe.app}
mkdir -p "$out/Contents/MacOS"
cat > "$out/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.neural.ble-prototype.mac</string>
<key>CFBundleExecutable</key><string>NeuralRelayProbe</string>
<key>CFBundleName</key><string>Neural Relay Probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>Receive test gestures and motion from Neural on your iPhone.</string>
</dict></plist>
PLIST
swiftc -module-cache-path /private/tmp/neural-swift-module-cache -O \
  "$root/NeuralIOS/Relay/RelayWire.swift" "$root/NeuralIOS/Relay/RelayKeyStore.swift" \
  "$root/Tools/WakeTrials.swift" "$root/Tools/MacRelayProbe.swift" -o "$out/Contents/MacOS/NeuralRelayProbe"
codesign --force --sign - "$out"
printf '%s\n' "$out"
