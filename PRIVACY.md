# Privacy

VoiceRevenue is local-first. Confirmed transactions are stored on the iPhone with Core Data. The project contains no ads, analytics SDK, telemetry, crash-reporting SaaS, maintainer server, or maintainer API key.

Audio is recorded locally. VoiceRevenue v0.1.2 uses Apple's Speech framework in an accuracy-first mode: when Apple's recognition service is available, the request is allowed to use network-backed recognition; if that fails and the device supports `vi-VN` on-device recognition, the same local recording is retried on-device. VoiceRevenue has no separate paid speech API account. Apple Speech behavior is subject to Apple's platform and privacy policies.

Product vocabulary and learned speech/product corrections are stored locally in UserDefaults.

Diagnostic logs are stored locally under the app's Application Support directory. They can contain transcripts, product/customer text, transaction amounts, parser decisions, and sync errors. Logs are never uploaded automatically. The user explicitly chooses whether and where to export them through the iOS share sheet.

Google Sheets sync is optional. If enabled, confirmed transaction data is sent only to the Google Apps Script Web App URL configured by the user. The project maintainer receives no copy of this data.

Users should review Apple's and Google's own privacy terms for services they choose to use.


The bundled v0.1.2 product catalog is derived from the store inventory workbook and remains inside the application. The full catalog is used locally for matching; only a bounded contextual shortlist may be supplied to Apple Speech as recognition hints.
