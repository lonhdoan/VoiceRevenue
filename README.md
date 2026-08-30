# VoiceRevenue v0.1

VoiceRevenue is a Vietnamese-first, local-first iPhone app for recording store revenue by voice. It is **free and open source (MIT)** and intentionally avoids paid APIs, advertising, analytics, tracking, subscriptions, and maintainer-controlled servers.

## What v0.1 does

1. Records audio with `AVFoundation`.
2. Transcribes Vietnamese using Apple's `Speech` framework (`vi-VN`).
3. Lets the user edit the transcript.
4. Parses candidate transactions locally with deterministic Swift rules.
5. Requires human review before saving accounting data.
6. Stores confirmed transactions locally with Core Data.
7. Calculates today's local revenue and transaction count.
8. Optionally syncs confirmed transactions to a Google Sheet through a user-owned Google Apps Script Web App.

No OpenAI API, Google Cloud backend, Firebase, paid SaaS, third-party Swift package, ads, telemetry, or maintainer account is required.

## Important limitation: speech is not universally offline

VoiceRevenue prefers on-device Apple Speech recognition when `SFSpeechRecognizer` reports that on-device recognition is supported. On other device/OS/locale combinations, Apple Speech may require Apple's service and an Internet connection. The app never claims universal offline speech recognition.

If recognition is unavailable, the recording is not intentionally uploaded to any VoiceRevenue server (there is no such server), and the workflow allows manual transcript entry.

## Requirements

- macOS with a compatible Xcode installation
- iPhone/iOS 15 or later
- Apple ID for installing a development build on a physical iPhone
- Google account only if optional Google Sheets sync is desired

The project source targets **iOS 15.0** and Swift 5 language mode.

## Build in Xcode

1. Download/clone this repository on a Mac.
2. Open `VoiceRevenue.xcodeproj`.
3. Select the `VoiceRevenue` target.
4. Open **Signing & Capabilities**.
5. Select your Apple ID/Personal Team.
6. If Xcode reports that the bundle identifier is unavailable, change `org.opensource.voicerevenue` to a unique identifier such as `com.yourname.voicerevenue`.
7. Connect your iPhone and trust the Mac if prompted.
8. Select the iPhone as the run destination.
9. Build and Run.
10. Grant Microphone and Speech Recognition permission when requested.

### Free Apple ID / Personal Team

Apple's free development provisioning is intended for development/personal use and has restrictions. Development-signed apps installed with a free Personal Team may need to be re-signed/reinstalled periodically according to Apple's current provisioning policy. VoiceRevenue does not require a paid Developer Program subscription for its source code or core runtime features.

For long-term distribution to many devices, consult Apple's current official signing/distribution rules. Community tools such as AltStore, SideStore, or Sideloadly may provide other personal sideload workflows, but they are **not dependencies of this project** and VoiceRevenue does not use jailbreaks, exploits, or security bypasses.

## End-to-end test

After installing on an iPhone:

1. Open VoiceRevenue.
2. Tap **Ghi doanh thu**.
3. Say, for example:
   `Lúc 7 giờ tối anh Nam thanh toán 350 nghìn tiền cái biển neon.`
4. Stop recording.
5. Check/edit the transcript.
6. Tap **Phân tích giao dịch**.
7. Verify customer, product, amount and time.
8. Edit any ambiguous field.
9. Tap **Xác nhận giao dịch**.
10. Confirm the Home screen revenue increased and the transaction appears in History.

Suggested multi-transaction test:

`Anh Nam 300 nghìn biển A, chị Hoa 500 nghìn biển B, anh Minh 1 triệu biển C.`

Suggested correction test:

`Anh Nam 350 nghìn, à không Nam 380 nghìn.`

The local parser is deliberately conservative. Always review accounting data.

## Parser coverage in v0.1

Examples intentionally covered include:

- `350 nghìn`, `350 ngàn`, `350k`, `350.000`
- `1 triệu`, `1 triệu 2`, `1 triệu 200`, `1 triệu rưỡi`
- `một triệu hai`, `một củ hai`, `hai củ rưỡi`
- `ba trăm rưỡi`, `ba trăm năm mươi nghìn`
- `7 giờ tối`, `7 rưỡi tối`, `19:30`, `19 giờ 30`
- honorific customer patterns such as `anh Nam`, `chị Hương`, `cô Lan`, `chú Minh`, `bạn An`
- payment methods `chuyển khoản`, `tiền mặt`, `bank transfer`, `cash`
- multiple transactions in one transcript
- basic same-customer explicit amount correction

This is not a general Vietnamese-language AI model. Unknown or ambiguous inputs should be edited during Review.

## Optional Google Sheets sync

VoiceRevenue works fully without Google Sheets.

To enable sync:

1. Create a Google Sheet.
2. In it, open **Extensions → Apps Script**.
3. Copy `google-apps-script/Code.gs` into the Apps Script editor.
4. Save and deploy it as a Web App.
5. Configure the deployment/access appropriate for your personal environment.
6. Copy the deployed `/exec` URL.
7. In VoiceRevenue open **Settings**.
8. Paste the URL into **Apps Script Web App URL**.
9. Tap **Kiểm tra kết nối**.
10. Tap **Thử đồng bộ lại** for pending transactions.

The Apps Script creates a `Transactions` sheet and rejects duplicate `transaction_id` rows.

Google Apps Script and Google Sheets are Google services and have their own quotas/policies. They are optional; a failure never deletes the local transaction.

## Data & privacy

See [PRIVACY.md](PRIVACY.md).

Core principles:

- local Core Data is the app's source of truth;
- no maintainer backend;
- no ads;
- no analytics;
- no tracking;
- no third-party crash reporting;
- no API keys;
- no service-account credentials;
- no user account required by VoiceRevenue.

## Zero-cost audit

| Component | Technology | Project/service cost | Account required? | Third-party code dependency? |
|---|---|---:|---|---|
| iPhone UI | SwiftUI | $0 | No | No |
| Audio | AVFoundation | $0 | No | No |
| Speech | Apple Speech | $0 charged by VoiceRevenue | Apple device services | No |
| Parsing | Local Swift | $0 | No | No |
| Database | Core Data | $0 | No | No |
| Networking | URLSession | $0 | No | No |
| Revenue dashboard | Local Swift/Core Data | $0 | No | No |
| Sheets sync | Google Apps Script + Sheets | $0 from VoiceRevenue; subject to Google quotas/policies | Google account, optional | No Swift dependency |
| App source/license | MIT | $0 | No | No |
| Basic device development install | Xcode + Personal Team | $0 software subscription from project | Apple ID | No |

Hardware, a Mac capable of running Xcode, an iPhone, Internet access, and third-party account policies are outside the software project's own service cost.

## Current known limitations

- The environment used to generate v0.1 did not have macOS/Xcode, so the full iOS app target could not be built or archived here.
- Parser/Foundation source was type-checked with the Swift compiler in the generation environment, and a standalone parser harness passed the core sample cases.
- Apple Speech quality and on-device availability vary by device, iOS version, locale and network state.
- Correction resolution is intentionally basic in v0.1.
- Product extraction is heuristic, not AI-powered.
- The Apps Script endpoint has no project-maintainer authentication layer. Treat the deployment URL as configuration and choose Google deployment access appropriate to your environment.
- A Core Data migration strategy is not yet required for v0.1; schema changes in future releases must add one.

## v0.2 ideas that stay free/open-source

- larger deterministic Vietnamese number grammar;
- customizable local product/customer dictionaries;
- stronger correction resolution;
- local fuzzy product matching;
- recording retry queue UI;
- local monthly summaries;
- CSV export/import;
- optional fully local open-source STT on sufficiently capable devices, without making it a requirement for old iPhones;
- improved duplicate/sync reconciliation;
- accessibility and localization improvements.

Paid cloud migration is intentionally not on the roadmap for core functionality.

## License

MIT. See [LICENSE](LICENSE).
