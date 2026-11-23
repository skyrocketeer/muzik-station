# Video import picker alignment plan

## Goal

Prevent the Files picker from advertising movie formats that the current import pipeline rejects, while preserving the existing video-import and playback work in the working tree.

## Assumptions and constraints

- Current supported video extensions remain `mp4`, `mov`, and `m4v` (`VideoFileSupport.extensions` in `Models.swift`). Expanding format support is out of scope because container extension alone cannot establish playable codecs.
- All file-picker entry points should match the existing video allowlist as closely as available Uniform Type Identifiers allow.
- Existing user changes in import, repository, model, and player files must be preserved.
- The Swift package test target is available for fast regression coverage; picker UI behavior itself needs an iOS build/device check.

## Plan

- [x] Review picker UTType behavior and choose an allowlist derived from supported video extensions.
- [x] Update Files picker entry points (library, onboarding, native importers) to stop advertising generic unsupported movie types.
- [x] Add repository regression coverage for same-title audio/video records remaining distinct.
- [x] Run `swift test` within the project budget; attempt an iOS app build if an appropriate Xcode destination is available.

## Files likely to change

- `localwave/Sources/Domain/Models/Models.swift` or a small UI utility for supported types
- `localwave/Sources/Features/Sync/Views/WaveFilesViews.swift`
- `localwave/Sources/Features/Sync/Views/WaveOnboardingView.swift`
- `localwave/Sources/Features/Shared/MainTabView.swift`
- `Tests/LocalWaveDataTests/ImportTests.swift` or a focused model test

## Verification

- [x] Repository regression test establishes audio/video metadata identity separation.
- [x] `swift test --quiet` passed within the 30-second budget.
- [x] Picker declarations use the supported types and routes continue passing selected file URLs to `addMusicURLs`.
- [x] iOS simulator app build attempt recorded: iPhone 17 simulator build timed out after 90 seconds during compilation; no compile error was reported before timeout. App compilation remains unverified.

## Clarification

- **Resolved:** picker video UTTypes will be derived from the existing `VideoFileSupport.extensions` values (`mp4`, `mov`, `m4v`), excluding the broad generic `.movie` type. The host SDK resolves these extensions to Uniform Type Identifiers.
- **Acknowledged risk:** extension-level allowlisting does not guarantee codec-level playback. AVFoundation may still reject a selected file with an unsupported codec; playback should surface its existing error.
- **Scope:** retain existing user changes for video selection/import/playback and add regression coverage for the audio/video metadata identity collision already fixed in the working tree. Do not broaden accepted container formats.
- **Sign-off:** user requested code changes and the above scope is directly limited to the identified picker/import blockers. Proceeding on that authorization (2026-11-20).

## Risks and open questions

- UTType declarations describe container/content types rather than guaranteeing codec-level playability. A selected supported-extension file can still fail AVFoundation decoding; this remains a runtime playback limit.
