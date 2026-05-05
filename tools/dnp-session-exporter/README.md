# dnp-session-exporter

Exports a single session under `memory/sessions/{id}/` to a portable bundle:

- `transcript.md` — already kept up to date by the Mac app
- `events.jsonl` — append-only event store
- `summary.md` — periodic summary
- `metadata.json` — Session metadata

Output: a `.zip` you can drop into any project tracker.

## Status

Stub. Implementation will use `Foundation.FileWrapper` + `Compression`.
