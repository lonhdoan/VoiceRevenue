# VoiceRevenue Privacy — v0.2.0

VoiceRevenue is local-first and does not include ads, analytics, tracking, telemetry, or a maintainer-controlled backend.

## Speech recognition

The default speech-to-text path uses the open-source `sherpa-onnx` engine and a bundled Vietnamese model. Audio and transcript processing happen on the iPhone and do not require Apple Speech or a cloud speech API.

The optional **Tăng độ chính xác bằng máy chủ riêng** feature is OFF by default. When the user explicitly enables it, VoiceRevenue sends the current recording to the endpoint URL configured by that user. The project does not operate or receive data from that endpoint.

## Local data

Confirmed transactions are stored in Core Data on the device. Product vocabulary, corrections, and self-hosted endpoint settings are stored locally. Diagnostic logs and the latest recording remain local unless the user explicitly shares/exports them.

Diagnostic exports may contain transcripts, customer names, products, amounts, recognition errors, and parser/sync metadata. Review them before sharing.

## Google Sheets

Google Sheets sync is optional. When configured, confirmed transaction fields are sent only to the user-supplied Google Apps Script Web App URL. Edited transactions are re-sent using the same `transaction_id` so the script can update the existing row.

## No credentials bundled

VoiceRevenue ships no paid API key, Google service-account credential, OpenAI key, or maintainer token.
