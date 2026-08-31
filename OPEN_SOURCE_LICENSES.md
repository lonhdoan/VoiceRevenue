# Open-source components — VoiceRevenue v0.2.0

This document is an attribution summary, not legal advice. Always preserve upstream license files/notices when redistributing third-party software or model weights.

## sherpa-onnx

- Project: https://github.com/k2-fsa/sherpa-onnx
- Pinned package: 1.13.6
- License: Apache License 2.0
- Role: local/offline ASR runtime and Swift wrapper

## Vietnamese Zipformer model

- VoiceRevenue model: `sherpa-onnx-zipformer-vi-int8-2025-04-20`
- Upstream sherpa-onnx model documentation: https://k2-fsa.github.io/sherpa/onnx/pretrained_models/offline-transducer/zipformer-transducer-models.html
- Source model: https://huggingface.co/zzasdf/viet_iter3_pseudo_label
- Source model license shown by upstream model page: Apache-2.0
- Role: Vietnamese speech-to-text model weights

## ONNX Runtime

- Project: https://github.com/microsoft/onnxruntime
- License: MIT
- Role: inference runtime dependency pulled by sherpa-onnx Swift Package

## Optional self-hosted reinforcement

VoiceRevenue does not bundle a server. The user may optionally point it to an API-compatible server they operate themselves.

A tested architectural target is Speaches:
- https://github.com/speaches-ai/speaches
- License: MIT
- STT backend: faster-whisper

faster-whisper:
- https://github.com/SYSTRAN/faster-whisper
- License: MIT

The license of any model selected on a self-hosted server remains the responsibility of the user/operator; it is not redistributed by VoiceRevenue.
