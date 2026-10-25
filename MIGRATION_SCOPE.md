# Migration scope

Current user instructions override the attached migration script's whole-runtime copy.

## Included

- 517 military source/configuration files selected from `ryoumiyahayato/wwo`, `archive/military-full-20261024`, commit `3c48266b335cfa448953d26b9698abb6dd207a34`.
- Vehicle crews, weapons, ammunition, armour, fire control, infantry, construction, terrain damage, Cedar/Rivergate and other military experiments.
- Military state/services and formal military adapter source at their original relative paths, with external host requirements.
- 17 early WarResolver v0 files, restored from raw Git objects at `canonical/current-world`, commit `28cdc2dc37c68161dc7b3a3254692980cc75e972`.
- Historical M development v9/runtime v8 only after the separate import below succeeds. It is never represented by v0.
- Original archived manifest and recovery tool. The manifest is a recovery index; it does not mean all referenced files or packages are migrated.

## Excluded

716 unrelated files from the script's runtime snapshot are listed in `provenance/SCOPE_EXCLUSIONS.json`. Economy implementation, formal global map, formal host application/UI/data and unrelated tooling/tests are not part of the final repository tree. The original source archive is preserved unchanged.

Military adapter host types (`WorldState`, `SimulationStep`, `FormalPersistence`, `FormalWorldApplication`, `WorldBootstrap`, `OrganizationState`, `AuthorizationCheck`, `VNextSpatialWorld` and their domain owners) remain external. No stub or replacement owner is created. Formal integration tests require the original host. No standalone engine recovery is claimed.

`military-godot/project.godot` differs from the archive only to remove the excluded formal-world default scene. This is a source extraction with no default application entry. Military source references are unchanged. Source assets omitted by the old readable snapshot, original private state and complete history are not recovered here.

## Remaining archive gap

All 18 logical ZIP packages remain in the original private WWO release: 114 physical assets, 7,192,143,243 bytes. Three packages are downloaded locally for M source recovery; this does not mirror them into the new repository's release assets. Exact package names, asset IDs, sizes and original checksums are in `provenance/ARCHIVE_GAPS.json` and the original manifest.

Other historical versions, reports, recordings, archives, caches, full current resources and private_state remain at the original archive. The old archive records a missing original APK and unverified external Drive objects; this migration does not resolve those gaps.

## Verification boundary

Only migration source, archive package/file restoration, remote privacy/branch/commit and fresh-clone file checks are in scope. No Godot import, native gameplay, GUI, Android, full test suite or repository-wide regression is claimed. No old WWO branch, release, save or worktree is modified or deleted.

## Historical M v9 import receipt

- Exact archive prefix: `wwo-person-attachment-20261011T0010/experiments/war_resolver/`
- Restored files: 423
- Status: M development phase v9 / runtime v8 historical source restored with archive per-file SHA256. This is NOT formal-world integration.
- Original GitHub private archive release assets still require separate mirroring or an explicit long-term preservation decision.
