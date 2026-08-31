# Build status — VoiceRevenue v0.1.4 emergency live speech patch

Generated and statically validated in a Linux environment without Xcode/iPhoneOS SDK.

## Runtime evidence used

The attached v0.1.3 / build 4 diagnostic from iOS 15.7.9 contains only:

- `app.session.started`
- `catalog.loaded` (`1267` products)
- `diagnostics.export.requested`

It does **not** contain recording or Speech method events. Source inspection found why this can happen after relaunch: v0.1.3 creates one log file per launch and `exportURL()` exports only the current session file, so prior-session Speech failures are omitted from the export.

## v0.1.4 changes

- Primary path is now live `SFSpeechAudioBufferRecognitionRequest` while the microphone is recording.
- `AVAudioEngine` provides one microphone tap for both live Speech and local CAF persistence, avoiding two competing capture stacks.
- Partial text is visible while recording and a non-empty partial is preserved if Apple never sends a final result.
- If live Speech returns no usable text, the same saved CAF is replayed through a new server-capable audio-buffer request.
- On-device replay runs only when `supportsOnDeviceRecognition == true`.
- Empty transcript can never reach `TransactionParser`.
- Diagnostic export aggregates up to five persisted sessions instead of exporting only the newest launch.
- Settings shows the most recent Live / Replay / On-device / Final Speech status and NSError domain/code/description.
- Retry and Diagnostics test reuse the same saved audio and never create a transaction by themselves.

## whisper.cpp decision

Not bundled in this emergency patch. The current official whisper.cpp XCFramework build script declares iOS 16.4 as its minimum, so its released XCFramework cannot be safely dropped into this iOS 15 app. Upstream source CI demonstrates lower deployment-target builds are possible, but VoiceRevenue would need a custom Xcode-built framework/model pipeline and real iOS 15 validation. Shipping that unverified C++ binary path in the same emergency patch would increase the chance of replacing a Speech runtime bug with a build/install failure.

## Verified here

- `swiftc -frontend -parse` succeeds for every Swift source and test file.
- Pure Foundation parser/model/catalog sources compile and the emergency parser harness passes: `HOTFIX_PARSER_GUARDS_OK`.
- `ProductCatalog.json` still contains 1,267 products.
- `Info.plist` passes `plutil -lint` and reports 0.1.4 / build 5.
- `project.pbxproj` passes `plutil -lint` and preserves `IPHONEOS_DEPLOYMENT_TARGET = 15.0`.
- No Core Data schema change.
- No paid API, account, backend, or new package dependency.

## Authoritative next verification

Push the patched source and run the existing macOS/Xcode 16.4 unsigned-IPA workflow. That workflow is the authoritative full iPhoneOS compile/package check. Then test one 5–10 second recording on the real iOS 15.7.9 device and confirm partial text appears while speaking.
