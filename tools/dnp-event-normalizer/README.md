# dnp-event-normalizer

Standalone CLI that consumes a JSONL event stream (from `.dnp/events/hooks.jsonl` or a saved
session export) and replays it through the same `EventNormalizerService` the Mac app uses.

Useful for offline debugging when iOS shows something unexpected.

## Status

Stub — uses the shared `EventNormalizerService`. Wire the executable in `Package.swift` once the
Mac normalizer is extracted into the shared package.
