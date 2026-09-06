# Personal downstream build

This fork retains Ainto's GPLv3 license and upstream attribution. `upstream`
continues to refer to ainto-labs/ainto-app; existing upstream contribution branches
are not rewritten. The fork's `main` is the personal product line, not an upstream
PR base. Use `upstream/main` when preparing upstream contributions.

## Version policy

Use immutable `downstream-YYYY.MM.DD-rcN` tags for test candidates, and a new
working branch for subsequent changes. The historical `integrated-2026.08.23`
tag remains at its previous commit; do not move it for new downstream versions.
An rc tag does not certify manual validation, signing, or notarization. Do not
publish a GitHub binary Release from an ad-hoc local build. Avoid `v*` tags: the
inherited release workflow treats them as binary publication triggers.

Only `/Applications/Ainto.app` may be launched for local testing. Existing
upstream bundle identity and config namespace are retained, so do not install
both variants simultaneously. Upstream Sparkle metadata is removed; this build
requires manual updates until a separately signed downstream feed is established.

## Reproduce CI locally

CI and `rust-toolchain.toml` pin Rust **1.98.1** with Clippy. Update both together
when intentionally upgrading. Keep `cargo clippy --all-targets -- -D warnings`:
new Clippy versions can reject code that passed an older local installation.
With rustup on PATH, the toolchain file selects the version automatically.
Homebrew's standalone Cargo does not honor it; check `rustc --version` and
`cargo clippy --version` before treating a local result as equivalent to CI.

## Snippets removal

Snippet management, Home/search entries, expansion, input monitoring, settings,
watchers, and Rust/Swift FFI are removed. Shared AI-command form controls remain.
Legacy snippet aliases can still decode and round-trip, but do not execute or
reserve aliases/hotkeys. Existing `snippets.toml` is not deleted. Obsolete snippet
config keys are accepted on read and omitted at the next ordinary config save.

## Correctness work in the first candidate

- Preserve malformed/unreadable aliases rather than treating them as empty.
- Keep old ranking counts during migration; commit pin-cache changes only after
  successful persistence.
- Separate clipboard file and text entries even when their bytes/hash match.
- Preserve unsent image-only Claude drafts and in-progress imports on stale reopen.
- Free the JSON returned by app discovery at startup and refresh.
- Isolate test clipboard writes and skip production attachment-cache cleanup in
  test view models.

## Remaining audit findings

The initial review covered critical Swift/Rust paths, not every line or every
third-party application. Passing tests is not a guarantee of no hidden bugs.
The following findings are **not fixed in this candidate** and remain follow-up
work, rather than being silently removed from the report:

- Synthetic-Copy fallback holds a pasteboard lease across main-actor suspension.
  Re-entering a synchronous clipboard action can deadlock. Removing TextExpander
  removes one automatic trigger, but not the general re-entry risk.
- Selection fallback lacks operation-scoped cancellation and can replay completion
  after subsequent navigation; external clipboard writes during the transaction
  are not reliably attributable and can be overwritten by restoration.
- An image import completing after leaving and re-entering Claude can attach to a
  newer draft; draft-generation cancellation needs deterministic coverage.
- Config/ranking writes are not yet atomic; clipboard recency ties have only
  second-level resolution. Alias save guards do not provide cross-process locking.
- Claude stderr completion ordering and output-size bounds need further study.

Do not describe this candidate as having resolved all lifecycle or persistence
issues. Mail/AX success paths avoid synthetic Copy, but AX support varies by app.
