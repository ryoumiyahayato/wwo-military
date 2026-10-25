# WWO Military

Private military source repository. One development branch: `main`.

- `military-godot/`: 517 military files selected from `current/runtime` at WWO archive commit `3c48266b335cfa448953d26b9698abb6dd207a34`. Vehicle crews, weapons, ammunition, armour, infantry, medical/construction modules, Cedar/Rivergate, military state and formal adapters retain their original relative paths.
- `research/m-v9/`: restored historical M algorithm, development v9 / runtime v8, when the second-stage import receipt is present.
- `legacy-research/war-resolver-v0/`: early reference only, never the latest M.
- `provenance/`: source commits, selected-file inventory, scope exclusions and original archive recovery index.

## Runtime boundary

The supplied migration script copied the complete archived runtime, including formal economy, global map and other host implementations. The user's current scope takes precedence: those implementations are excluded from this repository. The complete source archive remains unchanged in the original private WWO repository.

Military adapters and their integration tests reference external host types such as `WorldState`, `SimulationStep`, `FormalPersistence` and `FormalWorldApplication`. They require the original WWO host. No replacement economy, clock, ledger, world or map owner is created here. This repository is a military source extraction, not a self-contained runnable Formal application. Original military source references remain unchanged. `project.godot` has no default formal-world scene in this extraction.

Godot 4.6.3 source import, native execution, GUI and Android are not verified by this migration. Source-only recovery does not recover the omitted model/media resources, private saves or the complete history.

## Recovery

Clone this private repository using the authorized GitHub account. The committed source is the development copy. `provenance/archive/manifest.json.gz` and `restore_military.py` preserve the original authenticated recovery mechanism; its downloads still come from the original private WWO release. The M prefix is `wwo-person-attachment-20261011T0010/experiments/war_resolver/`.

Keep original WWO branches and all historical release attachments. No original branch, release, save or worktree is deleted by this migration. Archive preservation is not complete until all required historical assets have been separately verified or their retention in WWO has been explicitly agreed.
