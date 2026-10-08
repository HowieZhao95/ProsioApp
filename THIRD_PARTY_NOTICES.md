# Third-party notices

Prosio screenshot capture contains adapted source from [SnipSnipSnip](https://github.com/mc-hamster/SnipSnipSnip), fixed revision `7919eac9df9d9dec8427dbc0c10aecd32baf5530`.

Copyright (c) 2026 Oontz. Licensed under MIT; full license is retained in `THIRD_PARTY_LICENSES/SnipSnipSnip-LICENSE` and packaged in the macOS app as `ThirdPartyLicenses.txt`.

Retained platform, geometry, screenshot and editor adaptations are in `Apps/macOS/Prosio/Capture/`; native interaction and output integration are in `Apps/macOS/Prosio/UI/Editor/`. The source files retain their attribution and local adaptation notes.

Prosio meeting speaker analysis uses [FluidAudio](https://github.com/FluidInference/FluidAudio) at revision `20d4f0bd46d11d7f50a6eb4f7835cfdbd2b4ba14`. Licensed under Apache 2.0; the full license is retained in `THIRD_PARTY_LICENSES/FluidAudio-LICENSE`. FluidAudio diarization models are downloaded on first use into the user's model cache.

Prosio's experimental Jianying draft adapter is based on [pyJianYingDraft](https://github.com/GuanYixuan/pyJianYingDraft/tree/6bb2d06a713f7b58e1375269daec835a03882086), revision `6bb2d06a713f7b58e1375269daec835a03882086`. Copyright 2024 Gary Guan; Apache 2.0. Modified schema templates are attributed in `RecordingJianyingAdapter.swift`; the full license is retained in `Apps/macOS/Prosio/Recording/Export/pyJianYingDraft-LICENSE.txt` and included in the application and Jianying export package.

Prosio daily notes embeds Milkdown Crepe 7.22.2 and its bundled editor dependencies. The complete package versions and verbatim licenses are retained in `Apps/macOS/Prosio/Notes/Editor/NotesEditor/THIRD_PARTY_LICENSES.txt`, included in the app's `NotesEditor` resource folder. The editor is bundled locally and does not load runtime scripts from a CDN.
