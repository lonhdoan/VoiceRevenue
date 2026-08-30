# VoiceRevenue v0.1.2

VoiceRevenue is a Vietnamese-first, local-first iPhone app for recording store revenue by voice. It is **free and open source (MIT)** and intentionally avoids paid APIs, advertising, analytics, tracking, subscriptions, and maintainer-controlled servers.

## What v0.1.2 does

1. Records audio with `AVFoundation`.
2. Transcribes Vietnamese using Apple's `Speech` framework (`vi-VN`) with an **accuracy-first automatic mode**.
3. Uses up to 100 local product names as `contextualStrings` hints for Apple Speech and uses the `.dictation` task hint.
4. When Apple's online-capable recognition fails, retries the same recording on-device if that recognizer is supported on the iPhone.
5. Keeps Vietnamese diacritics in final customer/product data; accent-stripped normalization is internal only.
6. Uses a local product vocabulary, learned corrections, and conservative fuzzy suggestions before human review.
7. Parses multiple candidate transactions locally with deterministic Swift rules.
8. Requires human review before saving accounting data.
9. Stores confirmed transactions locally with Core Data.
10. Calculates today's local revenue and transaction count.
11. Exports local diagnostic logs on demand; logs are never automatically uploaded.
12. Optionally syncs confirmed transactions to a Google Sheet through a user-owned Google Apps Script Web App.

No OpenAI API, Google Cloud backend, Firebase, paid SaaS, third-party Swift package, ads, telemetry, or maintainer account is required.

## Speech accuracy policy

VoiceRevenue v0.1.2 prioritizes practical accuracy while keeping the core app at $0:

- When Apple Speech reports its service available, the app sends an online-capable request (`requiresOnDeviceRecognition = false`). Apple may use its service; VoiceRevenue does not have a separate paid speech API account or key.
- If that attempt fails and `vi-VN` on-device recognition is supported, the app retries the **same local recording** with `requiresOnDeviceRecognition = true`.
- Product vocabulary phrases are passed through `contextualStrings` (capped at 100 phrases) and also used by the local parser.
- A user-confirmed correction such as `tập gym → dập ghim` is stored locally and can be automatically applied next time.
- Fuzzy matches remain review-required; VoiceRevenue does not silently trust a low-confidence fuzzy correction.

Apple documents that on-device recognition may be less accurate than recognition that is allowed to use the network. VoiceRevenue therefore no longer forces on-device mode when online recognition is available.

### Why Whisper is not bundled in v0.1.2

`whisper.cpp` is open source and has an iOS example, but even its multilingual models add substantial disk/RAM cost (for example, tiny is roughly 75 MiB and base roughly 142 MiB before app overhead). On old iOS 15 devices this would materially increase IPA size, memory use, build complexity, and processing latency. WhisperKit-style integrations also commonly require newer deployment targets than this project. For v0.1.2, Apple Speech on-device remains the most practical offline fallback. A fully local Whisper option remains a possible v0.2 experiment for newer devices.

## Store catalog and two-pass recognition

v0.1.2 bundles the real store inventory catalog generated from `[Cửa hàng] Kiểm kê hàng tồn.xlsx`:

- 1,304 source product rows were read from 3 product sheets;
- 1,267 canonical product names are bundled;
- 37 exact duplicate names were removed;
- 62 blank-name rows were skipped;
- 0 malformed product rows were imported;
- 5 normalized-name collisions are intentionally retained because removing Vietnamese accents can collapse distinct products.

The full catalog stays local. It is **not** sent wholesale to Apple Speech. Online-capable recognition uses two conservative passes only when pass 1 produces evidence-backed catalog hints:

1. pass 1 recognizes the same local audio with a small priority context;
2. local catalog matching builds a bounded shortlist (max 100 Apple contextual phrases);
3. pass 2 reuses the **same audio** with that shortlist;
4. pass 2 is selected only when Apple's own average segment confidence materially improves. Catalog match count is logged for diagnostics but does **not** decide the winner, preventing self-reinforcing product hallucination.

Every canonical product emitted by the parser must be tied to a source phrase in the raw product span or to an exact user-learned correction whose source phrase is actually present. Unknown text remains raw and review-required rather than being forced to the nearest catalog item.

## Product vocabulary

Open **Settings → Từ điển mặt hàng** and enter one product per line, for example:

```text
dập ghim
dây điện
bấm móng tay
ốc vít
biển neon
```

The first 100 unique phrases are used as Apple Speech contextual hints. The local parser can use the same vocabulary to:

- preserve canonical Vietnamese spelling;
- extract multiple products into readable separate lines;
- apply user-confirmed corrections;
- propose conservative fuzzy matches for review.

## Diagnostics

Open **Settings → Diagnostics**. You can **Export Debug Log** and **Export Last Recording**.

The exported `.jsonl` file is stored locally and can include:

- app/build/iOS version;
- speech mode and availability;
- raw + normalized transcript;
- contextual vocabulary count;
- parser candidates, accepted evidence, and rejected fuzzy candidates;
- user-confirmed product corrections;
- Google Sheets request/result/error metadata.

Diagnostic logs may contain customer names, transaction amounts, products, and transcripts. They are never automatically uploaded. Only share them when you intentionally choose a destination from the iOS share sheet.

## Requirements

- iPhone/iOS **15.0 or later**
- Xcode 16.4-compatible build environment (the included GitHub Actions workflow can create an unsigned iPhoneOS IPA)
- Apple ID only for your chosen personal sideload/signing workflow
- Google account only if optional Google Sheets sync is desired

The project remains in Swift 5 language mode and does not use SwiftData or iOS 16+ APIs for core features.

## End-to-end local test

1. Open VoiceRevenue.
2. Open **Settings → Từ điển mặt hàng** and make sure your real products are listed.
3. Tap **Ghi doanh thu**.
4. Say: `Lúc 7 giờ tối anh Nam thanh toán 350 nghìn tiền biển neon bằng chuyển khoản.`
5. Tap the large **Dừng ghi âm** button.
6. Check/edit the transcript.
7. Tap **Phân tích giao dịch**.
8. Review customer/product/amount/time/method.
9. Confirm.
10. Confirm the transaction appears in History and today's revenue changes.

Suggested recognition-correction test:

```text
Say: dập ghim năm mươi nghìn
Possible Apple transcript: tập gym năm mươi nghìn
Expected: vocabulary fuzzy suggestion or a previously learned correction proposes dập ghim; fuzzy proposals remain review-required.
```

Suggested multi-item test:

```text
Anh Nam trả 250 nghìn gồm dây điện 5 mét, bấm móng tay và dập ghim.
```

Expected: one transaction with a readable multi-line product field.

Suggested multi-transaction test:

```text
Anh Nam 50 nghìn ốc vít, chị Hương 120 nghìn dây điện.
```

Expected: two candidate transactions.

## Optional Google Sheets sync

VoiceRevenue works fully without Google Sheets.

1. Create/open the target Google Sheet.
2. In that Sheet choose **Extensions → Apps Script**.
3. Copy `google-apps-script/Code.gs` into the editor and save.
4. In the Apps Script function selector choose **`setup`**, click **Run**, and authorize it. Run `setup()` once before deploying. It stores the target spreadsheet ID in Script Properties and creates the `Transactions` tab if needed.
5. Choose **Deploy → New deployment → Web app**.
6. Configure the web app to execute as the deploying user/owner.
7. Because VoiceRevenue intentionally has no Google OAuth flow, the Web App must be callable without interactive sign-in. Use the anonymous-access option when your Google account/domain offers it.
8. Deploy and copy the versioned URL ending in `/exec`.
9. In VoiceRevenue open **Settings → Google Sheets**.
10. Paste the `/exec` URL and tap **Kiểm tra kết nối**.
11. A successful health check confirms that the endpoint is VoiceRevenue v0.1.1+ and can access/create the `Transactions` sheet.
12. Use **Đồng bộ lại X giao dịch** for pending/failed rows.

`setup()` is required because Google documents that active-container methods such as `getActiveSpreadsheet()` are not available to a bound script when it executes as a Web App. The setup step captures the sheet ID while run from the editor; the deployed endpoint then reopens that exact spreadsheet with `SpreadsheetApp.openById(...)`.

Do not use a `/dev` Test deployment URL. `/dev` is reserved for Apps Script development testing and requires script-editor access.

If a Workspace administrator does not permit anonymous Web Apps, this zero-OAuth sync architecture cannot operate with that account. VoiceRevenue remains fully usable local-only.

## Data & privacy

See [PRIVACY.md](PRIVACY.md).

Core principles:

- local Core Data is the app source of truth;
- no maintainer backend;
- no ads, analytics, tracking, or remote telemetry;
- no project API key or service-account credential;
- diagnostic logs stay local until the user exports them;
- Apple Speech may send audio to Apple services when online-capable recognition is used;
- Google Sheets sync sends confirmed transaction data only to the Apps Script URL configured by the user.

## Zero-cost audit

| Component | Technology | Project/service cost | Account required? | Third-party code dependency? |
|---|---|---:|---|---|
| iPhone UI | SwiftUI | $0 | No | No |
| Audio | AVFoundation | $0 | No | No |
| Online-capable speech | Apple Speech | No metered API bill from VoiceRevenue | Apple device services | No |
| Offline fallback | Apple Speech on-device when supported | $0 | No | No |
| Vocabulary/corrections | Local Swift + UserDefaults | $0 | No | No |
| Parsing | Local Swift | $0 | No | No |
| Database | Core Data | $0 | No | No |
| Diagnostics | Local JSONL + iOS share sheet | $0 | No | No |
| Networking | URLSession | $0 | No | No |
| Sheets sync | Google Apps Script + Sheets | $0 from VoiceRevenue; Google quotas/policies apply | Google account, optional | No Swift dependency |
| Source/license | MIT | $0 | No | No |

## Known limitations

- Apple Speech quality, online service availability, and on-device `vi-VN` support vary by device/iOS/network.
- Setting `requiresOnDeviceRecognition = false` allows online-backed recognition but does not expose a public API proving whether Apple actually processed a specific request on a server; VoiceRevenue logs this mode as `online` to mean **online-capable/preferred**.
- Contextual vocabulary improves likelihood, not certainty.
- Fuzzy matching is intentionally conservative and still requires human review.
- Product segmentation remains deterministic rather than a general-language AI model. Unknown/ambiguous products intentionally require review.
- Google Apps Script access options can be restricted by Google Workspace administrators.
- The generation environment for this patch does not contain macOS/Xcode; GitHub Actions remains the authoritative full iOS build/test environment.

## License

MIT. See [LICENSE](LICENSE).
