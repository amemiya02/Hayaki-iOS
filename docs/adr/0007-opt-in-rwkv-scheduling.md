# Patch the core with an opt-in RWKV review queue

Status: accepted

Hayaki for iOS adopts the decision in [Android ADR-0009](https://github.com/amemiya02/Hayaki/blob/main/docs/adr/0009-opt-in-rwkv-scheduling.md). A switch in Settings lets the learner queue review Cards by an RWKV model's predicted recall instead of by their stored due dates. With the switch off, the app schedules exactly as upstream Anki does.

`vendor/anki` moves from upstream Anki at tag `26.09.4` to a Hayaki fork of that tag. The fork changes how review Cards are gathered and counted, and links Fushi's `fushi_rwkv` inference crate. Android and desktop build from the same fork. The switch is the collection config key `hayakiRwkvScheduling`, which syncs to every device. RWKV state is rebuilt on each device from the synced review log and is never synced.

## Consequences

- This replaces "The core is used unpatched" in [ADR 0001](0001-embed-ankis-rust-core.md) for scheduling only. Sync, storage and package import and export stay upstream's code, so the condition for AnkiWeb access in [ADR 0005](0005-android-parity.md) still holds.
- Each core upgrade rebases the patch onto the new upstream tag before the Swift calls are regenerated.
- The app downloads the small model's weights, about 436 KB, from the author's pinned URL when the learner first turns the switch on. The terms for those weights are recorded in the Android decision.
- Replay time and memory on iPhone are unmeasured. The [specification](https://github.com/amemiya02/Hayaki/blob/main/.scratch/rwkv-scheduling/spec.md) measures them in its iOS phase before the switch ships.
