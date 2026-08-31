# VoiceRevenue v0.2.0 Build Status

## Release target

- Marketing version: 0.2.0
- Build: 6
- Deployment target: iOS 15.0
- Swift language mode: 5.0
- Core Data schema migration: none

## Open-source STT

- Engine: sherpa-onnx 1.13.6 (Swift Package pinned exactly)
- Runtime dependency: ONNX Runtime through sherpa-onnx
- Model: sherpa-onnx-zipformer-vi-int8-2025-04-20
- Model archive SHA-256: `48d0fdc9b3515eb9b00c4dfec2883207ee5ebe5c95b1959e7afce87fc3391938`
- Runtime mode: local CPU, 1 thread, 16 kHz mono float input
- Apple Speech required for core STT: no

## Validation performed in patch-generation environment

- Swift syntax parse for all project Swift files: pending final packaging validation
- Pure Swift parser harness: PASS for contextual `giá`/money-cue cases and `1tr2`
- Info.plist lint: PASS
- project.pbxproj plist lint: PASS
- Apps Script JavaScript syntax: PASS
- Product catalog remains >= 1,000 entries / expected 1,267 resource

This environment does not contain macOS/Xcode, so it does not claim an iPhoneOS compile. The existing GitHub Actions Xcode workflow is authoritative for the full device build and tests.
