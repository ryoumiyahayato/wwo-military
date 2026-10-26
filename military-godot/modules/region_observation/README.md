# Bounded region observation module

Reusable Godot 4.6 training scenery. This is a library, not a new game or main scene.
Coordinates are local metres. The region is fictional and not geographically registered.
It owns no authoritative world state, clock, actors, military/economic commands or saves.
The host owns UI, camera, movement and permissions. Main-repository integration is a separate PR.

## API

Instantiate `LayeredTerrain` from the module resource below as a `Node3D` and add it to the host tree.
Connect `prepared`, `changed` and `failed(message)` before calling `begin(config)`.

```text
res://modules/region_observation/layered_terrain.gd
```

- `begin(config: Dictionary)`: restart loading. `training_only` must be true; false is rejected.
- `base_path`: project-local asset root. Default is `res://`; a trailing slash is added when needed.
- `center`: local X/Z in a `Vector2`. Default is zero; coordinates are clamped to the region.
- `span_m`: view span, clamped to 50–75000 metres. Default is 50000.
- `collision_enabled` / `collision_layer`: default true / 1. Collision is local training support only.
- `update_view(center: Vector2, span_m: float)`: change observation targets without creating world facts.
- `sample_height(x: float, z: float) -> float`: source-backed local height. Returns `NAN` before data or outside coverage.
- `is_ready()`: the first real source-backed patch is installed, not the whole queue.
- `is_collision_ready(position: Vector3)`: all tiles for the local safety square are installed. Visual readiness alone is insufficient.
- `get_status()`: bounded presentation status, counts and `resource_notes`; not a world snapshot.
- `close()`: stop processing, join the worker and release owned resources. Also called on tree exit.

`TerrainHeightSource` is pure data work. `read_sources`, `sample` and `build_patch` do not access the scene tree.
Height sampling uses the same triangle diagonal as fine meshes and local collision.

## Bounds and sources

At most 100 coarse 5 km tiles, one 5 km overview, nine fine 500 m tiles and four local collision tiles.
One data/mesh worker runs at a time. At most one mesh and one collider are installed per frame.
Local collision covers the view centre's +/-64 m safety square only when fine detail is active.
No whole-region collision or full-world preload is created.

The 50 km view uses the original 50 m height grid. A 25 km view uses that same source, not a new dataset.
The native 5 km patch uses the original 4 m height grid. No source heights are exaggerated.

Assets remain incomplete in this source extraction. This PR copies no large assets.
Required metadata and regional height data are resolved under `base_path`:

```text
continuous/assets/region.json       # continuous-training-region-v1, training_only
continuous/assets/height_50m.f32     # 1001 x 1001 float32; required, currently absent here
ridgevale/assets/height_4m.f32       # 1251 x 1251 float32; optional native detail, absent here
```

Missing required regional data emits `failed`; missing native detail leaves the valid regional view available.
Optional colour, normal, control and detail textures retain the original `continuous/assets/`, `ridgevale/assets/` and `cedar/assets/` paths.
Missing optional textures are reported in `resource_notes`. They do not create substitute geographic facts.

## Canonical source / vendor adaptation

Fixed current copies from the main WWO repository:

```text
wwo/scripts/presentation/terrain/layered_terrain.gd
  -> military-godot/modules/region_observation/layered_terrain.gd
wwo/scripts/presentation/terrain/terrain_height_source.gd
  -> military-godot/modules/region_observation/terrain_height_source.gd
wwo/shaders/presentation/terrain/layered_ground.gdshader
  -> military-godot/modules/region_observation/layered_ground.gdshader
```

Only three constants in `LayeredTerrain` are adapted: the two preloads point to `res://modules/region_observation/`, and the default asset root changes from `res://assets/terrain/region_slice/` to `res://`.
The height source and shader are unchanged. All other terrain logic is unchanged.
Treat these files as vendored copies of that canonical implementation, not an independent terrain rewrite.

## Validation boundary

No Godot run, tests, audit or export was performed for this military-module PR.
This source extraction has no default main scene and lacks external host/vehicle dependencies and original assets.
No claim is made that the military project is independently runnable.
The main host's initial window routing was previously verified by the lead; that is not validation of this module extraction.
Final integration validation remains with the lead.
