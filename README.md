# VoiceRevenue v0.2.0

VoiceRevenue is a Vietnamese-first, offline-first iPhone app for recording store revenue by voice. The app is MIT-licensed and intentionally avoids paid APIs, advertising, analytics, tracking, subscriptions, and maintainer-controlled servers.

## v0.2.0 architecture

Core speech recognition no longer depends on Apple Speech.

```text
Microphone / local CAF recording
        ↓
sherpa-onnx 1.13.6
Vietnamese Zipformer INT8 model
        ↓
RAW Vietnamese transcript
        ↓
local corrections + 1,267-product catalog
        ↓
deterministic transaction grammar
        ↓
human review
        ↓
Core Data
        ↓ optional
Google Sheets via user-owned Apps Script
```

The local STT engine is `sherpa-onnx`, with `sherpa-onnx-zipformer-vi-int8-2025-04-20`. The model is processed on the iPhone with no network requirement. The app remains usable in Airplane Mode after the model is included in the build.

### Optional self-hosted reinforcement

Settings contains **Tăng độ chính xác bằng máy chủ riêng**. It is OFF by default. When enabled, VoiceRevenue first obtains the local transcript, then may send the same audio to an endpoint owned/configured by the user, for example a local Speaches/faster-whisper server. If the endpoint is unavailable, local recognition still succeeds independently.

Audio is never sent to the optional endpoint unless the user explicitly enables it.

## Offline model provisioning

The v0.2.0 patch installer provisions the official model before you build the IPA. This makes the built app offline-ready immediately and avoids a first-run account/network flow.

Pinned archive:

```text
sherpa-onnx-zipformer-vi-int8-2025-04-20.tar.bz2
SHA-256: 48d0fdc9b3515eb9b00c4dfec2883207ee5ebe5c95b1959e7afce87fc3391938
```

Normal patch apply downloads this exact archive from the sherpa-onnx GitHub release, verifies SHA-256, extracts the required files into `VoiceRevenue/Resources/SherpaVI`, and then you commit/push normally.

For a completely offline Windows provisioning workflow, download the pinned archive once on another machine and run:

```powershell
.\apply-v0.2.0.ps1 "C:\path\to\VoiceRevenue" -ModelArchivePath "C:\path\to\sherpa-onnx-zipformer-vi-int8-2025-04-20.tar.bz2"
```

## Vietnamese transaction grammar

v0.2.0 treats money cues as part of the amount grammar instead of blindly including them in product text.

Examples:

```text
bút bi giá 20 nghìn
→ Product: bút bi
→ Amount: 20,000

giá 50 nghìn dây điện
→ Product: dây điện
→ Amount: 50,000

giá 50 nghìn
→ Product: nil / review required
→ Amount: 50,000

giá đỡ điện thoại 50 nghìn
→ Product: giá đỡ điện thoại
→ Amount: 50,000

Vít 20 giá 10.000
→ Product: Vít 20
→ Amount: 10,000
```

`giá` is not globally deleted. It is treated as a money cue only when it is directly attached to the detected money span, so real product phrases such as `giá đỡ điện thoại` remain intact.

Money parsing also supports compact speech/text notation such as `1tr2` → 1,200,000 VND.

## Store catalog

The bundled catalog contains 1,267 canonical products generated from the real store inventory. It stays local and is used only after a real transcript exists for exact matching, accent-insensitive matching, learned corrections, product-vs-money-cue disambiguation, and conservative fuzzy suggestions.

The parser never forces every phrase into a catalog item. Unknown text remains raw and review-required.

## Editable History

Open **History**, tap a transaction, and edit:

- amount;
- customer;
- product;
- payment method;
- date/time;
- notes.

Save preserves the existing `transactionID` and `createdAt`. Cancel does not mutate the stored transaction. If Google Sheets is configured, an edit marks the transaction pending and re-syncs it.

## Google Sheets UPSERT

The v0.2.0 Apps Script uses `transaction_id` as the stable key:

```text
ID not found → append a row
ID found     → update the existing row
```

This prevents edited history records from creating duplicate rows. Local editing works offline; a later sync updates Sheets when connectivity returns.

If you already deployed an older Apps Script, replace it with `google-apps-script/Code.gs`, save, and create a new deployment/version so the `/exec` URL runs the upsert code.

## Diagnostics

Diagnostics remain local-only and can include:

- STT engine/model/version;
- local inference duration and real-time factor;
- local transcript;
- optional self-hosted transcript;
- arbitration decision;
- parser evidence;
- history edits;
- sync result.

Logs and recordings are never automatically uploaded.

## Requirements

- iPhone with iOS **15.0 or later**
- Xcode 16.4-compatible build environment (the included GitHub Actions workflow builds the unsigned iPhoneOS IPA)
- no Apple Speech permission for core STT
- no paid API/account/backend for core operation
- Google account only for optional Google Sheets sync

## End-to-end acceptance test

1. Put the iPhone in Airplane Mode.
2. Open VoiceRevenue and confirm Settings reports the sherpa-onnx model ready.
3. Record a Vietnamese transaction such as `bút bi giá hai mươi nghìn`.
4. Stop, review the local transcript, parse, and save.
5. Open History, edit the transaction, and save it.
6. Re-enable network; if Sheets is configured, verify the same `transaction_id` row is updated rather than duplicated.

## Open-source components

See `OPEN_SOURCE_LICENSES.md` for the engine/model/runtime notices used by this release.

## Privacy

See `PRIVACY.md`.

## License

VoiceRevenue: MIT. See `LICENSE`.
