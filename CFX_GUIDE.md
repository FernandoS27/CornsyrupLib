# The CFX Language — User & Programming Guide

CFX is the readable, editable text format for **PopcornFX war3 particle effects** (the `.pkb` /
`.particles` baked containers used by Warcraft III Reforged and Diablo II Resurrected). The
`cornsyrup` tool converts a baked `.pkb` **into** a CFX bundle you can read and edit, and **back**
into a runtime-identical `.pkb`.

```
pkb  ──decompile──▶  CFX bundle (a folder of .cfx files)  ──build──▶  pkb
```

The round-trip is **lossless at the runtime level**: rebuild an unedited bundle and it behaves
identically (validated across the whole corpus: runtime-identical and byte-idempotent).
Edit a formula, a curve, a color, or a spawn count, rebuild, and the change takes effect.

> **Fidelity note.** The goal is *runtime-identical*, not *byte-identical*. cornsyrup recompiles the
> bytecode fresh from your edited code, so the rebuilt `.pkb` may differ byte-for-byte from the
> original while producing the same simulation.

---

## Table of contents

1. [The bundle](#1-the-bundle)
2. [Common value syntax](#2-common-value-syntax)
3. [The `header` block](#3-the-header-block)
4. [`effect.cfx` — attributes & graph](#4-effectcfx)
5. [`samplers.cfx`](#5-samplerscfx)
6. [`renderers.cfx`](#6-rendererscfx)
7. [Event declarations](#7-event-declarations)
8. [The layer coding language (`code.cfx`)](#8-the-layer-coding-language)
9. [The layer system](#9-the-layer-system)
10. [Emission — how particles spawn](#10-emission)
11. [Events](#11-events)
12. [Payloads](#12-payloads)
13. [Functions (`functions.cfx`)](#13-functions-functionscfx)
14. [Templates](#14-templates)
15. [Reference tables](#15-reference-tables)

---

## 1. The bundle

A CFX bundle is a directory containing these files. Owned data is nested under its container;
cross-references between files use `&handle` names that resolve when the bundle is merged on build.

| File | Contents |
|---|---|
| `effect.cfx` | Leads with the bundle **`header`** (format/engine/family), then the **structure**: attributes and the layer **graph** (topology). |
| `code.cfx` | Everything per-layer: each layer's **`properties`** (samplers, spatial layers, attributes, renderer links, and the `metaData`/`child` compiler flags), its **`event`/`root` declarations** (payload shapes), its **programs** — the editable simulation code (spawn + per-frame) — and its renderer input **`bind`** blocks. |
| `samplers.cfx` | Sampler data: curves (keyframes), shapes, turbulence, event streams. |
| `renderers.cfx` | Renderer materials and their feature values / textures. |

Plus one **optional** file, authored rather than decompiled: `functions.cfx` — reusable `fn`
definitions (§13) and `template` declarations (§14), which expand at build and never come back from
a `decompile`. (`decompile` does write the file when it does not already exist, but only to carry
the `import` lines that reconstructed calls need — §13.6. It never overwrites one you wrote.)

Four generated files — there is **no** `manifest.cfx` (its header merged into `effect.cfx`), **no** `fields.cfx`
and **no** `events.cfx` (both were per-layer data keyed by layer name, so they moved into the layer's own
block in `code.cfx` — one place to read a layer, and no cross-file name to keep in sync), and **no**
separate metadata file for the compiled bytecode: the per-call binding is derived on build, and baked
spawn-input constants are inlined directly into `code.cfx`.

> A bundle that still has a standalone `events.cfx` (or `fields.cfx`) from an older cornsyrup still
> builds, but both files are deprecated: each is read only when `code.cfx` declares nothing of its
> own, and `build` warns either way — that the file will not be read by the next release, or that
> `code.cfx` already carries its data and the file changes nothing. Decompiling the `.pkb` again
> writes the data into `code.cfx`.

**Identifiers are free-form.** Layers, samplers, and renderers are declared with an identifier that works
like a variable name — the decompiler emits readable defaults (`L0`, `sd3`, `rend0`), but you may rename
any of them to anything (`layer my_fire_ring`, `sampler fade_curve`, `renderer smoke`). As long as you use
the same name at every reference across the bundle, the build resolves it. Every `&handle` reference
(`&L4`, `&sd12`, `&rend3`) and the graph's `&<layer>` edges follow whatever names you choose.

### General file conventions

- **Comments.** `//` runs to end of line; `/* … */` is a block, and **blocks nest**:

  ```
  /* disabled for now:
     Position = Position + Velocity /* per second */ * scene.dt;
  */
  ```

  Nesting is the one deliberate departure from C and C++, and it is there for exactly the case
  above: commenting out a region that already contains a `/* … */` must not end early on the inner
  `*/` and leave a stray closer behind. Rust, D and Swift nest for the same reason. An unterminated
  `/*` is an error naming the line it opened on, rather than a puzzle about the end of the file.
  Both forms work in every `.cfx` file — structure, code, and `functions.cfx` alike.
- **Comments are not preserved.** `decompile` regenerates a bundle from the bytecode, which has no
  record of them, so anything you write is lost on the next decompile — the same discipline the
  format already needs for identifier names. Keep the `.cfxb` directory as your source of truth.
- Whitespace is insignificant (indentation is cosmetic).
- Every file begins with a short header comment describing its own syntax.

---

## 2. Common value syntax

These value forms appear throughout the structure files (and, where noted, in code).

| Form | Meaning |
|---|---|
| `42`, `-7` | integer |
| `3.14`, `-0.5`, `1e-4` | float |
| `1.4e-45@0x00000001` | float with an **exact-bits** suffix — used when the decimal wouldn't reparse to the same 32-bit pattern |
| `true` / `false` | boolean |
| `(1, 0, 0, 0)` | a tuple / vector (2–4 components) |
| `[a, b, c]` | an array |
| `"text"` | a string (use `\"` and `\\` to escape) |
| `&handle` | a cross-reference to another node (e.g. `&sd12`, `&rend3`, `&L4`) |
| `&null` | a null reference |
| `loc[6647399 => "War3"]` | a localized string: `langKey => payload` |
| `f32x4`, `i32x2`, `Curve`, … | a **named enum** — numeric type/kind fields render as names for readability (fully reversible) |

**Named enums.** Numeric "kind" fields render as names: e.g. `SamplerType = Shape`,
`ShapeType = Cylinder`, `ExportedType = f32x4`, `PayloadType = f32x3`. Any value the tool doesn't
have a name for stays numeric — nothing is ever lost.

---

## 3. The `header` block

`effect.cfx` opens with a `header` block — the bundle header (you rarely edit it) plus the root effect
node's links. The former `manifest.cfx` is gone; this replaces it.

```
header {
    format = "cfx/1";           // bundle text format version
    cfx_version = 100;          // CFX schema version
    family = Warcraft3;         // effect family — expands the fixed pkb-header
                                //   fields (engine version, baker, revision id,
                                //   byte markers)
    LayerGraphCompileCache = &graph;   // the graph node (below)
    AttributeFlatList = &attrs;        // the attribute list (below)
}
```

`family` is the shorthand for the constant header fields every bake of a given game carries; they're
regenerated on build. There are **two** families, and only two:

| `family` | engine | generator | version byte | revision id | reserved |
|---|---|---|---|---|---|
| `Warcraft3` | `2.5.1` | `baker` | `0xCA` | `0x0000F7D7` | `0` |
| `Diablo2` | `2.9.5` | `baker` | `0xCA` | `0x00001F40` | `0` |

The family is keyed on **`major.minor`** — 2.5.x is Warcraft III, 2.9.x is Diablo II, and an engine
version outside those two is not a family at all (`decompile` refuses it rather than inventing a
header). Verified across the whole corpus: every baked Warcraft III `.pkb` and Diablo II `.particles`
carries its game's one header tuple; the only exceptions are the few hand-authored files below.

> **The family normalises.** A 2.5.2 bake collapses to `family = Warcraft3`, so the next build writes
> 2.5.1 / `0xF7D7` — not the values it came in with. That is the intent: a bundle records *which game*
> an effect is for, and the shipped values for that game are the ones the game loads. In the corpus
> this rewrites only a few hand-authored files.

---

## 4. `effect.cfx`

The authoritative structure file: the `header` (above), the effect's **attributes**, and the **layer
graph** (which layers exist and how events connect them). Per-layer details now live in `code.cfx`
(§8). It has readable `header`/`attributes`/`graph` blocks plus a generic `node H : Type { … }`
fallback for anything without a dedicated form.

### 4.1 Attributes

Host-provided, named values the effect exposes (e.g. a game-driven color or scale multiplier).

```
attributes {
    "Game.ColorMultiplier" : f32x4 {
        default = (1, 0, 0, 0)
        max     = (3, 0, 0, 0)
    }
    "Game.Global.Spawning" : f32 {    // f32 is the default; the pkb omits it, we show it anyway
        HasMin = true
        HasMax = true
        default = (1, 0, 0, 0)
        max     = (1, 0, 0, 0)
    }
}
```

- Header: `"ExportedName" : Type` — `Type` is an engine base type (`f32`, `f32x3`, `f32x4`, `bool`, …) and
  is **always shown**. `f32` is the engine default (the pkb leaves `ExportedType` unstored for it); the
  header still displays `: f32`, and rebuilding it re-omits the field, so nothing is added.
- `default` / `min` / `max` are readable aliases for `DefaultValueF4` / `MinValueF4` / `MaxValueF4`.
- Other fields (`HasMin`, `HasMax`, `Semantic`, `CategoryName`, `UseSlider`) appear verbatim.

**A standard attribute by its name alone.** The attributes the game sets itself (the `Game.*` and
`Weather.*` names of §8.9, `Game.Global.Spawning` and `Game.Event.OnBirth`/`OnDeath`) are declared
word for word alike in every Warcraft III effect, so `effect.cfx` may name one alone and the build
reads the standard declaration in its place (`src/vocab/attributes.rs` holds them). `decompile`
writes this form wherever a declaration is the standard one:

```
attributes {
    "Game.EmissionRateMultiplier";      // f32 on a slider up to 3, default 1, in the War3 category
    "Game.TeamColor";                   // f32x4 colour, default white
}
```

A standard attribute may also go undeclared here altogether: when a layer binds one by its name
alone (`attrib "__a_Game.EmissionRateMultiplier";`, §8.1) and `effect.cfx` does not declare it, the
build declares it, after the effect's own. There is only one way to declare it, so the layer's
binding says all the declaration would. This is what lets a layer template (§14.4) bring the game
attributes it reads. Any other attribute is the effect's to declare.

The `ExportedName` is what the host game looks up, by **exact string compare**. Ten of these names
are written by Warcraft III itself, and code refers to those by constant rather than by name — see
[§8.9](#89-engine-attribute-constants). Every other name is an effect-local value: it exists in the
editor and keeps whatever `default` says, because nothing outside the effect ever writes it.

### 4.2 The graph

The **emission topology** — which layers spawn which, driven by which events — as human-readable edges.
Each layer is referred to by its identifier (`&L0`, or whatever you renamed it to). Each line is one edge:

```
graph {
    coordsys = (1, 5, 3, 1);

    spawn &L0;                                          // the effect root spawns layer L0
    &L0 emits "Signal" -> [&L1, &L2, &L3, &L4];         // L0 fires "Signal" → these layers spawn
    &L6 emits "__e_Child" -> &L7;                        // L6's child-spawn event spawns L7
    &L6 emits "__e_OnDeath";                             // an event with no spawn targets
    &L8 emits "__e_Child" -> [&L9, &L10];

    entry;                                               // an (empty) top-level entry point
    entry "Root" fires &L0."Signal";                     // the named entry fires L0's "Signal" event
}
```

- **`spawn &L`** — the effect root directly spawns layer `&L` (the top of the tree).
- **`&L emits "Event" -> <targets>`** — layer `&L` fires event `"Event"`; each target layer (`&LN`, or a
  `[…]` list) spawns when it does. An event with no `->` fires but spawns nothing (e.g. `__e_OnDeath`).
- **`entry ["name"] [fires &L."Event"]`** — a top-level trigger the host can fire; `fires` points at the
  layer event it routes to.

Reading top-to-bottom shows the whole spawn tree. (Under the hood these edges are stored as numeric slot
arrays; the readable form and the slot indices are fully equivalent and reconstructed on build.)

Per-layer details (samplers, spatial layers, attributes, renderer links, constant data) are **not** here —
they live in each layer's `properties` block in `code.cfx` (§8.1).

---

## 5. `samplers.cfx`

Sampler data — the curves, shapes, and noise the code samples.

```
sampler sd1 : Curve {
    keys 4 {  // 1 ch, hermite
        0    = 0    in 0 out 0
        0.3  = 1    in 0 out 0
        0.65 = 0.9  in 0 out 0
        1    = 1    in 0 out 0
    }
}

sampler sd23 : Shape {
    SampleDimensionality = 3;
    Position = (0, -1.5, 0);
    ShapeType = Cylinder;
    Height = 0.2;
}

sampler sd32 : Turbulence { Strength = 0.01; Wavelength = 1; }

sampler sd0 : EventStream { Times = [0]; }
```

- **Curves** use MDL-style keyframe blocks: `keys N { t = value in <tan> out <tan> }`. The value/
  tangent **arity is the channel count** (a `f32x4` color curve has 4 numbers per keyframe). The
  `// 1 ch, hermite` comment notes channels and interpolation. See §5.1 for the two interpolators.
  A curve's `ValueType`, its channel count, is that arity when it is not written; `decompile`
  writes it only when it is something else.
- **Shapes** describe an emission volume (`ShapeType` ∈ `Box`, `Sphere`, `Cylinder`, `Capsule`,
  `Cone`, `ComplexEllipsoid`, `Mesh`) with `Position`, `Height`, `Radius`, etc. `Mesh` spawns from
  real geometry in an external `.pkmm` file — see §5.3.
- **Turbulence** is a **vector field** — either procedurally generated curl noise or a baked file
  (§5.2).
- **EventStream** is a timeline of trigger times.

Each `sdN` handle is referenced from a layer's `sampler … = &sdN` line and from `code.cfx` by the
sampler's **name** (`__sampler_N`).

### 5.1 Curve interpolation — `Linear` vs `Spline`

A `Curve` sampler carries an `Interpolator` (`CInterpolableVectorArray::EInterpolator`), and it decides
**what the format stores**, not just how the curve is drawn:

| `Interpolator` | Evaluation | `FloatTangents` |
|---|---|---|
| `Spline` *(default)* | cubic Hermite through the keys, using their in/out tangents **raw** (never scaled by the segment span) | exactly `2 x FloatValues` — an in and an out tangent per value |
| `Linear` | a plain `Lerp` between control points | **empty** — the node drops the array entirely |

That second column is the part worth remembering. `Spline` is the engine's class default, so a block that
writes tangent-free keys and *omits* `Interpolator` leaves the engine hermite-interpolating an empty
tangent array. CornSyrup therefore always writes `Interpolator = Linear;` for a linear curve, and always
writes `in`/`out` tangents for a spline one, so a `keys` block is never ambiguous:

```
sampler sd7 : Curve {
    Interpolator = Linear;      // ← required; tangents are absent by definition
    keys 3 {
        0   = 0
        0.5 = 1
        1   = 0
    }
}
```

Other `Curve` fields, all carried through verbatim by the tools: `MinLimits` / `MaxLimits` (float4 output
clamps), `IsLoopedCurve` (adjusts edge values and tangents so last→first is smooth), `IsProbabilityCurve`
(builds a CDF and exposes `sampleCDF` to scripts), and `Quality` (`Exact` *(default)* / `High` / `Medium` /
`Low` — a runtime speed-vs-memory tradeoff with no effect on the authored data).

### 5.2 Turbulence / vector-field samplers

A `Turbulence` sampler answers "what is the wind here?" — `sampler.sample(position)` returns a **velocity
vector**, which scripts typically accumulate into `velocity` or `position`. `DataSource` picks where that
velocity comes from:

| `DataSource` | Meaning |
|---|---|
| `Procedural` *(default)* | the curl-noise generator below — nothing external is loaded |
| `External` | a baked field loaded from the `.pkvf` file named by `VectorFieldResource` (the PKVF Baker makes one from an `.fga`) |

The two sources use **disjoint** property sets; the engine hides the irrelevant half in its own editor,
and the CornSyrupTools **Vector Field** tab does the same.

#### How a procedural field is built

1. **Octave stack.** The authored knobs become an fBm stack: the first octave has
   `wavelength = GlobalScale · Wavelength` and `amplitude = GlobalScale · Strength`; each further octave
   multiplies wavelength by `Lacunarity` and amplitude by `Gain · GainMultiplier`.
2. **Vector potential.** That stack is evaluated three times (decorrelated) to give a potential field Ψ.
3. **Flow.** The sampled velocity is `curl(Ψ)·FlowFactor + (Ψ − curl(Ψ))·DivergenceFactor`. The default
   `FlowFactor = 1, DivergenceFactor = 0` is therefore a pure **divergence-free** curl-noise flow — air
   swirling without sources or sinks — and the engine special-cases exactly that pair for speed.
4. **`FastFakeFlow`** abandons the curl for a single-layer gradient. Much cheaper, visibly worse, and no
   longer divergence-free — which is why it *freezes* `FlowFactor`/`DivergenceFactor`.

> ⚠ **`Lacunarity` multiplies the WAVELENGTH, not the frequency.** Values below 1 make each successive
> octave *finer*; hence the engine's default of `0.5` and its `[0, 1]` range, which is the opposite
> convention from most fBm implementations. Setting `Lacunarity = 1` (or `Gain = 0`) collapses the stack
> to a single octave carrying the summed amplitude.

#### Every property

| Property | Type | Default | Range | Source | Meaning |
|---|---|---|---|---|---|
| `DataSource` | enum | `Procedural` | — | both | `Procedural` \| `External` |
| `VectorFieldResource` | string | — | — | External | path to the baked `.pkvf` field file |
| `GlobalScale` | float | `1` | — | both | scales **both** `Strength` and `Wavelength` |
| `Strength` | float | `0.1` | — | both | field strength; higher = larger forces |
| `Wavelength` | float | `0.5` | — | Procedural | turbulence scale — bigger = larger vortices |
| `Octaves` | uint | `2` | `[1, 12]` | Procedural | noise layers blended together |
| `Lacunarity` | float | `0.5` | `[0, 1]` | Procedural | wavelength factor between octaves (see warning) |
| `Gain` | float | `0.5` | `[0, 1]` | Procedural | amplitude factor between octaves |
| `GainMultiplier` | float | `1` | — | Procedural | multiplier on `Gain`; above 1 the noise goes unstable |
| `Interpolator` | enum | `Cubic` | — | Procedural | `Linear` \| `Cubic` \| `Quintic` lattice fade |
| `Filtering` | enum | `Trilinear` | — | External | `Point` \| `Trilinear` \| `Quadrilinear` grid filter |
| `WrapSide` | bool | `true` | — | External | repeat instead of clamp on the side axis |
| `WrapVertical` | bool | `true` | — | External | …on the vertical axis |
| `WrapDepth` | bool | `true` | — | External | …on the depth axis |
| `WrapTime` | bool | `true` | — | External | …on the time axis |
| `TimeScale` | float | `0` | — | Procedural | animation speed; `0` = frozen, `1` = loops every second |
| `TimeBase` | float | `0` | — | Procedural | time offset into the animation |
| `TimeRandomVariation` | float | `0.5` | `[0, 1]` | Procedural | spreads per-vortex rates over `TimeScale ± v/2` |
| `FlowFactor` | float | `1` | `[-2, 2]` | Procedural | how much divergence-**free** (curl) flow to keep |
| `DivergenceFactor` | float | `0` | `[-2, 2]` | Procedural | how much curl-**free** flow to mix back in |
| `InitialSeed` | uint | `1114229502` | — | Procedural | randomises the noise |
| `FastFakeFlow` | bool | `false` | — | Procedural | cheap single-layer gradient instead of the curl |

Defaults matter: a property the asset omits takes the value above, so `sampler sd32 : Turbulence
{ Strength = 0.01; }` is a 2-octave Cubic field with wavelength 0.5, not a bare single-octave one.

```
sampler sd11 : Turbulence {
    CustomName = loc[6647399 => "TurbLoFreq"];
    Strength = 0.5;
    Wavelength = 2;
    Interpolator = Linear;
    TimeScale = 1;          // animate: the field churns, looping once a second
    TimeBase = 1;
    TimeRandomVariation = 1;
    FlowFactor = 0.10400009;   // mostly cancelled…
    DivergenceFactor = 0.12800002;  // …and mixed with curl-free flow
}
```

---

### 5.3 Mesh shape samplers and `.pkmm`

A `Shape` sampler with `ShapeType = Mesh` spawns from real geometry instead of a primitive volume:

```
sampler sd1 : Shape {
    ShapeType = Mesh;
    MeshResource = "Meshes/StanfordDragon_LOD2.pkmm";
    MeshScale = (1, 1, 1);
    SubMeshIndex = 0;
    MeshSamplingMode = Uniform;
}
```

| Field | Meaning |
|---|---|
| `MeshResource` | Path to the baked mesh, resolved by the **engine** against the game's data root |
| `MeshScale` | Per-axis scale applied to the mesh, default `(1, 1, 1)` |
| `SubMeshIndex` | Which sub-mesh to sample when the file holds several |
| `MeshSamplingMode` | `Fast` (naive per-triangle), `Uniform` (constant surface/volume density, the default), `Weighted` (vertex-colour weighted) |
| `DefaultUvStream` / `DefaultColorStream` | Which channel `sampleTexcoord()` / `sampleColor()` read when the mesh has several |
| `DensityColorStream` / `DensityChannel` | For `Weighted`: which colour stream and which of `Red`/`Green`/`Blue`/`Alpha` weights the density |

**The mesh is not in the bundle.** `MeshResource` points outside it, so a `.cfxb` is not
self-contained the way it is for curves and textures — copying a bundle without its meshes gives you
an effect that loads and spawns nothing.

**The mesh arrives rotated.** A `.pkmm` records the coordinate frame its geometry is stored in, and
the engine converts it into its own on load (`CResourceMeshFileSerializer_V01::TransposeCoordinates`).
Warcraft III initialises the runtime `RightHand_Z_Up`, and every baked mesh seen so far is stored
`RightHand_Y_Up` — so positions and normals come out as `(x, y, z) -> (x, -z, y)`, and a mesh read
straight off disk is lying on its side. If the source frame is left-handed the conversion mirrors,
and triangle winding is reversed to match.

**Only `.pkmm` works.** The engine's mesh loader is version-gated with no extension sniffing and no
fallback (`CResourceMesh::_VirtualLoad`), so a `.pkmm` is the only thing this path can point at.
**MDX is not an option here** — that is a different pipeline. (Mesh *renderers* are the opposite
case: Warcraft III hands the `Mesh` feature's path to its own `ModelCreate`, and those **are** MDX.
Same word, unrelated mechanisms.)

#### Inspecting a mesh

```
$ cornsyrup-dev blob mesh Meshes/MeshFlipbook03.pkmm
Meshes/MeshFlipbook03.pkmm
  version 0  sub-meshes 7
  stored RightHand_Y_Up -> engine (x, -z, y)
  [0] 01                        89 verts      120 tris  material="Default"
        …
        Position       f32x3 simd16
        Normal         f32x3 normalized simd16
        Texcoord       f32x2
  …
```

That is the only way to see what a sampler is actually sampling: how many sub-meshes exist (what
`SubMeshIndex` may address) and which vertex streams are present (what `sampleTexcoord()` and
`sampleColor()` can read). `cornsyrup-dev` is the development tool that comes with the source, not
with a release: `cargo run -p cornsyrup-dev -- blob mesh <file.pkmm>` from the repository.

#### Editing one

The **Shape Sampler** tool in `cornsyrup-tools` edits Mesh shapes like any other kind. Because the
geometry is external it does something the other shapes never need: it loads the `.pkmm` and shows
you what is in it — the sub-mesh list drives the `SubMeshIndex` dropdown by name and triangle count,
the viewport draws the mesh's real triangles, and the sample preview scatters points using the
selected distribution, so `Fast` vs `Uniform` vs `Weighted` is something you can see rather than
guess at. To load the mesh it looks beside the effect first (inside the bundle, then the folders
above it, when Mill hosts the tool and knows where the bundle is) and then in the installed game's
archive; `MeshResource` itself is left exactly as written, since the engine resolves it against the
game's data root.

Two mesh-only behaviours show up there:

* **Vertex** sampling means what it says. Mesh is the only shape that overrides the engine's
  `SampleVertex` — every other kind inherits a base that forwards to `SampleSurface` — so spawns land
  exactly on the mesh's vertices.
* The panel repeats the build-time checks below inline, against the loaded file.

#### Build-time checks

When the referenced mesh happens to sit next to the bundle, `build` reads it and reports
contradictions — an out-of-range `SubMeshIndex`, a stream index the mesh does not have, `Weighted`
sampling on a mesh with no colour stream, or a file that is not a loadable mesh:

```
warning: sampler sd1: SubMeshIndex = 4 but Meshes/StanfordDragon_LOD2.pkmm has 1 sub-mesh
```

These are **warnings and never fail a build**, and a path that does not resolve locally is silent —
the engine resolves it elsewhere, so an unresolved path means nothing. Nor does a `DefaultUvStream`
of 0 on a mesh with no UVs: 0 is the default value, not a request.

## 6. `renderers.cfx`

Renderer **materials** — how a layer's particles are turned into drawn geometry. Same declaration style as
samplers: a `renderer <name> : <Type>` header naming the **geometry type**, then one `Name = value;` line
per **non-default** property. A renderer is linked from a layer's `Renderers = [&rendN]` (§8.1); its input
**bindings** (which particle fields feed which draw slots) live in `code.cfx` as a `bind` block (§8.2), not
here — the wiring sits beside the code that produces those fields.

```
renderer rend0 : Billboard {
    DrawOrder = 1;                                 // renderer node field (not a material feature)
    EnableRendering = true;
    Transparent = true;                            // enable a feature…
    Transparent.Type = AlphaBlend;                 // …then set its fields
    Diffuse = true;
    Diffuse.DiffuseMap = "…/FB_Smoke_8x8.tif";     // texture path
    SoftParticles = true;
    SoftParticles.SoftnessDistance = 0.6;          // float
    Atlas = true;
    Atlas.Source = 1;                              // int
    Atlas.SubDiv = (8, 8);                          // int2 grid
    Atlas.MotionVectorsMap = "…/Distort.dds";
    BillboardingMode = PlaneAligned;               // orientation enum (always shown)
}
```

### 6.1 Renderer (geometry) types

The header type is the renderer's **geometry** — how each particle becomes drawable. It is stored as the
first material property, `Geometry<Type>`, and selects the default material `Default_<Type>.pkma`.

| Type | Geometry | In the WC3 corpus |
|---|---|---|
| **`Billboard`** | a screen/axis-oriented quad per particle | dominant — nearly every renderer |
| **`Ribbon`** | a connected strip threaded along a trail of particles | occasional — beams, trails, lightning |
| **`Light`** | a dynamic point light per particle | engine geometry type; **unused** in WC3 |
| **`Mesh`** | a model instanced per particle (`path = "units/…/footman.mdx"`) | supported (`pkMeshPolicy`); **unused** by the WC3 corpus |

### 6.2 Value forms

Every property is `Name = value;` (no `prop` keyword) — the value token is self-describing and **typed**,
never a raw bit pattern:

| Form | Example | Meaning |
|---|---|---|
| **flag** | `Diffuse = true;` | a feature toggle (enabled) |
| **texture** | `Diffuse.DiffuseMap = "…/tex.tif";` | an asset path (`.tif` / `.dds` / …) |
| **float** | `SoftParticles.SoftnessDistance = 0.6;` | a scalar |
| **int** | `Atlas.Source = 1;` | an integer selector / count |
| **enum** | `Transparent.Type = AlphaBlend;` | a **named** enum — §6.5 / §6.6 |
| **tuple** | `Atlas.SubDiv = (8, 8);` | a small vector (a grid, etc.) |

> **Every property is a float4 slot in the engine.** CornSyrup writes the readable scalar or enum when
> lanes 1–3 sit at their defaults, and falls back to the raw tuple when they do not — so
> `Transparent.Type = AlphaBlend;` and `Transparent.Type = (0, 3, 3, 3);` are both normal, and a scalar
> like `SoftParticles.SoftnessDistance = (0.15, 0, 0, 0);` is too. **Lane 0 carries the value**; a
> reader that assumes a bare scalar will choke on real corpus renderers.

> **A bundle from an older cornsyrup may spell two floats as integers.** `decompile` wrote the lanes
> of `LightAttenuation.AttenuationSteepness` and `Doppler.DopplerFactor` as their bit patterns:
> `(1048576000, 0, 0, 0)` for `(0.25, 0, 0, 0)`. `build` still reads that spelling — in those two
> properties, an integer at least 2^23 (8,388,608) from zero is a float's bit pattern — and warns
> with the float to write instead. A smaller integer is its value, as in any float property (`1` is
> 1.0).

### 6.3 Renderer node fields

Three things belong to the renderer node itself, not the material — they use the same `Name = value;` form
but are not features:

- **`DrawOrder = N;`** — draw/sort priority among the effect's renderers.
- **`RendererClass = N;`** — the renderer class id. This is `ERendererClass`
  (`Billboard 0 · Ribbon 1 · Mesh 2 · Light 3 · Sound 4`), i.e. **the same thing as the header type**,
  so it is fully derivable and omitted at the Billboard default. The corpus never disagrees:
  Billboard omits it, Ribbon writes `1`.
- **`material = "<path>";`** *(optional)* — override the default `Default_<Type>.pkma` (e.g. a
  `Distortion_Billboard.pkma`). Omitted when the material is the canonical default for the type.
- **`path = "<file>";`** *(Mesh only)* — the model file. This is the readable hoist of the engine's
  **`Mesh` material property** (`SID_Mesh`), not a separate node field. Warcraft III reads it in
  `pkMeshBatchKey::Configure`, runs it through `pkSystem::ArchiveRelativePath`, and hands it to the
  game's **own `ModelCreate`** — so it is an archive-relative **MDX/MDL** path, not a PopcornFX
  `.pkmm`. (`pkMeshPolicy` then makes one `HMODEL` per particle and animates it with the particle
  transform; the `MeshAtlas` feature adds a per-particle `MeshID` stream that picks the sub-model.)

### 6.4 Features & their fields — the full registry

A material is a set of **features**; enabling one (`Feature = true;`) unlocks its dotted **fields**
(`Feature.Field = value;`). This is the complete set of material properties the engine registers
(`BasicRendererProperties::Startup` and `CRenderHelpersInternals::Startup`), grouped by role, and it is
exactly the registry CornSyrup and its editors use (a test keeps the two equal). Field value forms:
*(tex)* texture, *(f)* float, *(i)* int, *(b)* bool, *(enum)* named enum.

**Core / surface**

| Feature | Fields | Role |
|---|---|---|
| `EnableRendering` | — | master on/off (default on) |
| `Transparent` | `.Type` (enum §6.6), `.SortMode` (i) | transparent blending |
| `Opaque` | `.Type` (i), `.MaskThreshold` (f) | opaque / alpha-cutout path |
| `Diffuse` | `.DiffuseMap` (tex) | base colour texture |
| `Emissive` | `.EmissiveMap` (tex) | additive glow |
| `Distortion` | `.DistortionMap` (tex) | screen-space distortion (heat haze) |
| `DiffuseRamp` | `.RampMap` (tex) | 1-D colour lookup |
| `EmissiveRamp` | `.RampMap` (tex) | 1-D emissive lookup |
| `AlphaRemap` | `.AlphaMap` (tex) | 1-D alpha lookup |
| `SoftParticles` | `.SoftnessDistance` (f) | depth-fade against nearby geometry |

**Atlas (flipbook / sub-UV animation)**

| Feature | Fields |
|---|---|
| `Atlas` | `.Source` (i), `.Definition`, `.SubDiv` (i2 grid), `.Blending` (i), `.MotionVectorsMap` (tex), `.DistortionStrength` (f) |

**UV controls**

| Feature | Fields | Role |
|---|---|---|
| `TextureUVs` | `.FlipU` (b), `.FlipV` (b), `.RotateTexture` (b) | per-axis UV flips / rotate |
| `FlipUVs` | — | flip both axes |
| `TextureRepeat` | — | wrap instead of clamp: tiling (Ribbon, §6.8) |
| `TransformUVs` | — | UV transform |
| `CustomTextureU` | — | custom U coordinate (Ribbon); the game reads the `TextureU` input, not this (§6.8) |
| `CorrectDeformation` | — | deformation correction (Ribbon) |

**Lighting**

| Feature | Fields |
|---|---|
| `Lit` | `.NormalMap` (tex), `.SpecularMap` (tex), `.RoughMetalMap` (tex), `.Roughness` (f), `.Metalness` (f), `.CastShadows` (b) |
| `LegacyLit` | `.NormalMap` / `.SpecularMap` (tex), `.NormalWrapFactor` / `.LightExponent` / `.LightScale` / `.AmbientLight` (f), `.CastShadows` (b) |
| `NormalBend` | `.NormalBendingFactor` (f) |
| `NormalWrap` | `.WrapFactor` (f) |
| `CastShadows` | — |

With `Lit` on, Warcraft III's own renderer reads `Lit.NormalMap` and `Lit.SpecularMap` and binds
the textures. `Lit.SpecularMap` is not in the PopcornFX material, so no baked effect has it, but a
bundle that writes it is read.

**Light, mesh, sound, shader inputs, billboard geometry**

| Feature | Fields | Role |
|---|---|---|
| `Light` / `LightTranslucent` | — | Light geometry emission |
| `LightAttenuation` | `.AttenuationSteepness` (f) | light falloff |
| `MeshAtlas` | — | Mesh: a per-particle `MeshID` input picks the sub-model |
| `Sound` | `.SoundData` (asset) | Sound geometry |
| `SoundAttenuation` | `.AttenuationModel` (i) | sound falloff |
| `Doppler` | `.DopplerFactor` (f) | Doppler shift |
| `ShaderInput0` / `ShaderInput1` / `ShaderInput2` / `ShaderInput3` | — | custom material shader inputs |
| `EnableSize2D` | — (b) | Billboard: independent width × height |
| `BillboardingMode` | *(enum §6.5)* | Billboard: quad orientation — **always shown** |

A Mesh renderer's model is the `Mesh` property, written `path = "…"` (§6.3).

The engine registers the renderer's **inputs** in the same lists — `Color`, `Cursor`, `TextureID`,
`TextureU`, `Enabled`, `SortKey`, `Range`, `Volume`, `Velocity`, `Input0`… — but they are not material
properties: they are particle fields, which a `bind` block wires (§8.2 lists them all). A light's colour and range, a
ramp's cursor, a diffuse tint are bound, not written here. `EmissiveColor` is one too (the renderer
interface declares it an input), and Warcraft III reads it neither as a property nor as an input, so
`build` refuses `EmissiveColor = …;` in a renderer block; to colour the particles, bind a field to
`Color`.

> Most of these are Billboard-oriented; a typical WC3 renderer touches only a handful — `Transparent`,
> `Diffuse`, `EnableRendering`, `Atlas`, `SoftParticles`, `BillboardingMode`. Everything else reconstructs
> at its default (§6.7).

**A feature belongs to a geometry.** `TextureUVs`, `TextureRepeat`, `CustomTextureU` and
`CorrectDeformation` are **Ribbon** features: the Billboard material has no slot for them, so
`TextureUVs.RotateTexture = true;` on a Billboard cannot turn anything. `build` refuses it and says
which geometry the feature belongs to — it used to drop the line in silence, and the effect built
and did nothing. An **AxisAligned billboard therefore cannot rotate its texture**; use `PlaneAligned`
(§6.5), whose quad you can orient, or a Ribbon.

Everything else you write is **kept**, whether or not this guide lists it: a sub-property of a
feature the geometry does have (`Lit.Roughness` on a Billboard) is written as authored, and a name no
material is known to have is written with a warning, since the registry above records what has
shipped rather than everything the materials define.

**Some properties are read by nothing in Warcraft III** (the registry's `inert` badge: `TransformUVs`,
`Emissive`, `DiffuseRamp`, `LegacyLit`, `NormalWrap`, …). Setting one (`TransformUVs = true;`) builds
and changes nothing in game, and `build` warns that it does.

### 6.5 `BillboardingMode` — quad orientation

How a Billboard particle's quad is oriented each frame. **Always shown** (even at its default) so the
orientation is never implicit. The axis modes read the renderer's `Axis0` / `NormalAxis` inputs. A
Ribbon reads the same property under names of its own (below).

| Value | Orientation |
|---|---|
| `ScreenAligned` *(default)* | quad parallel to the screen plane (up = screen up); the default when a renderer has no `Axis` input |
| `ViewposAligned` | quad turns to face the camera **position** per-particle, not the flat screen plane |
| `AxisAligned` | quad pivots around a fixed axis `Axis0`, facing the camera around it — beams, trails, lightning. `Axis0` is the **full** polar length (the quad spans `±Axis0/2`) |
| `AxisAlignedSpheroid` | camera-facing spheroid; `Axis0` only sets the in-plane twist/stretch — flares, glints |
| `AxisAlignedCapsule` | capsule around `Axis0` |
| `PlaneAligned` | quad lies flat in a fixed plane (`Axis0` = side, `NormalAxis` = normal) — ground decals, teleport runes |

**On a Ribbon** the property is the ribbon mode, and it has three values. The game reads the number
as 0, 1 or 2 and draws any other as 0; PopcornFX 2.5.1 has no tube and no multi-plane ribbon.

| Value | Strip |
|---|---|
| `ViewPos` *(default)* | camera-facing |
| `NormalAxisAligned` | the `Axis` input is the strip's **normal** |
| `SideAxisAligned` | the `Axis` input is the **width** direction |

`build` refuses a Ribbon in any other mode (`AxisAlignedSpheroid`, `3`). The billboard names still
build on a Ribbon, as the number each stands for, with a warning: `ScreenAligned` is `ViewPos`, but
`ViewposAligned` is `NormalAxisAligned` and `AxisAligned` is `SideAxisAligned` — so a camera-facing
ribbon written `ViewposAligned`, as PopcornFX's ribbon documentation names it, came out normal-axis
aligned. `decompile` writes the ribbon names.
### 6.6 `Transparent.Type` — blend mode

The blend equation used while `Transparent` is enabled. Only lane 0 is read; the engine maps it to its
internal `m_BlendMode` and picks the GPU blend factors:

| Value | Result | src, dst factors | Typical use |
|---|---|---|---|
| `Additive` *(default)* | `src + dst` | `SRC_ALPHA, ONE` | fire, glow, energy, sparks |
| `AdditiveNoAlpha` | premultiplied additive | `ONE, ONE` | already-lit additive textures |
| `AlphaBlend` | alpha-over | `SRC_ALPHA, ONE_MINUS_SRC_ALPHA` | smoke, splashes, decals |
| `PremultipliedAlpha` | premultiplied alpha-over | `ONE, ONE_MINUS_SRC_ALPHA` | pre-multiplied textures |

When `Transparent` is **off** and `Opaque` is on, `Opaque.Type` chooses `0` = opaque (depth-tested, no
blend) or `1` = alpha-cutout (alpha-test). Getting this wrong is visually dramatic — additive blows out a
smoke core that `AlphaBlend` renders correctly — so the enum is spelled out, never a raw number.

### 6.7 Defaults are omitted (template reconstruction)

A property left at its default value is **not written**; the full ordered property set is reconstructed from
a per-geometry-type **template** on build (RE'd byte-exact for Billboard and Ribbon). So:

- A renderer block shows only what differs from the default material — short and readable.
- `BillboardingMode` is the single always-shown exception, so orientation is explicit.
- If the tool ever meets a renderer its template can't reconstruct, it falls back to listing **every**
  property (bare features as `Name;`), so the round-trip is never lossy.

```
// A Ribbon (beam), and a Billboard with a custom distortion material:
renderer rend1 : Ribbon {
    EnableRendering = true;
    Transparent = true;
    Diffuse = true;
    Diffuse.DiffuseMap = "…/Lightning.tif";
    CorrectDeformation = true;
    TextureRepeat = true;
    BillboardingMode = ViewPos;
}
renderer rend3 : Billboard {
    material = "Popcorn/Library/PopcornFXCore/Materials/Distortion_Billboard.pkma";
    Distortion = true;
    Distortion.DistortionMap = "…/Distort.dds";
    BillboardingMode = ScreenAligned;
}
```

### 6.8 Ribbons

A Ribbon threads one strip through the live particles a parent spawned. What the game does with it
(Warcraft III 3.0, PopcornFX 2.5.1; the evidence is in `docs/engine/renderer-properties.md`,
"Ribbons"):

- **A strip is one parent's live particles, newest first.** The game sorts a draw's particles on
  `ParentID`, then on `SelfID`, newest first, and joins two neighbours only when their `ParentID`s
  match. `SelfID` is written at spawn from a counter that rises with every spawn; `ParentID` is the
  kicking particle's `SelfID`, all ones for a spawn from the root. A disabled particle is skipped. So
  the layer needs `child;`, and its `bind` needs `"SelfID" -> SelfID;` and
  `"ParentID" -> ParentID;` (§8.2).
- **`SizeScale` is the half width**: a point's two vertices sit at `p ± SizeScale · side`, the side
  normalised. The full width is twice `SizeScale`.
- **The modes** (§6.5): `ViewPos` faces the camera; `NormalAxisAligned` takes the `Axis` input as the
  strip's normal, `SideAxisAligned` as its width direction. In both, each point uses the axis of the
  point before it in the strip (its newer neighbour), and the first point its own. There is no tube
  and no multi-plane ribbon.
- **The axis is `Axis`** (semantic 8), not `Axis0`, which a Ribbon never reads.
- **A point's own U is the `TextureU` input.** When it is bound, each point's U along the strip is its
  value; when it is not, every segment spans U from 0 to 1, so the texture repeats once per segment.
  `CustomTextureU = true;` is what the material calls the feature, but the game reads only the input:
  the switch without the input warns.
- **`TextureRepeat` is the wrap switch.** Without it the diffuse, normal and specular maps clamp, and
  the alpha remap map never wraps. A ribbon whose `TextureU` runs past 1 needs `TextureRepeat`, or the
  edge texel smears along the rest of the strip.

A minimal trail, for a layer spawned by a kick that carries `Position`:

```
renderer Trail : Ribbon {
    Transparent = true;
    Diffuse = true;
    EnableRendering = true;
    CustomTextureU = true;
    TextureRepeat = true;
    BillboardingMode = ViewPos;
    Diffuse.DiffuseMap = "…/Trail.dds";
}

// in code.cfx, the layer
    properties { Renderers = [&Trail]; child; }
    …
    bind Trail {
        "Position" -> Position;
        "Width"    -> SizeScale;     // half the width
        "Enabled"  -> Enabled;
        "SelfID"   -> SelfID;
        "ParentID" -> ParentID;
        "U"        -> TextureU;      // each point's U along the strip
    }
```

---

## 7. Event declarations

Every layer block in `code.cfx` (§8) declares its **payload schema**: the exact shape of each data
packet that flows in or out when particles spawn. These declarations hold no logic (that is the layer's
`init`/`evolve`) and no routing (that is the graph in `effect.cfx`) — only the **contract** the two sides
of a spawn agree on. Think of them as the `struct` definitions that the code's
`appendPayload`/`extractPayloadElement` calls read and write, sitting in the same block as the code that
reads and writes them.

> These used to live in a separate `events.cfx`, keyed by layer name. They are per-layer data, so they
> now sit in the layer. An older bundle that still has the file keeps building, with a deprecation
> warning — it is read only when `code.cfx` declares no events of its own (§1).

Each layer declares two kinds of thing:

- **`root { … }`** — the layer's **root event**: the payload a newborn of *this* layer receives at birth.
  This is the layer's "birth certificate" — the ordered attributes (Position, Velocity, Color, …) the
  spawn machinery hands a new particle.
- **`event NAME { … }`** — a **kick event**: the payload the layer *sends* when its code runs
  `NAME.kick(…)`. Each is a fan-out the graph (§4.2) routes to one or more child layers.

```
layer L4 {
    event __e_OnSpawn {          // this layer emits "__e_OnSpawn"; here is what it carries
        EmittedCount;            // bare name — a canonical attribute (Type/Kind implied)
        Position = 7176;         // canonical name + non-default flags
        Color;
        Size;
    }
    root;                        // empty root — a newborn inherits nothing (a top spawner)
}

layer L9 {
    event "__e_Signal 1" {       // names may contain spaces ⇒ quoted
        Position = 7176;
        Color;
    }
    root auto;                   // root derived from the graph on build (§7.5)
}
```

### 7.1 Anatomy of a payload field

Every line inside an `event`/`root` block is one **payload element**, terminated by `;` like every other
CFX declaration. Its full form has four parts:

```
Name : Type = Flags kind Kind;
```

| Part | Meaning |
|---|---|
| **`Name`** | the attribute's identity — `Position`, `Color`, `EmittedCount`, … (stored as a name-hash) |
| **`Type`** | the engine base type of the value — `f32x3`, `f32x4`, `quaternion`, `f32`, `i32`, … |
| **`Kind`** | a spawn-routing tag: `Position` (1), `Orientation` (2), `EmittedCount` (3), or none (0) — §7.2 |
| **`Flags`** | packed bookkeeping bits — §7.4 |

In practice you almost always see just a **bare `Name;`**, or `Name = Flags;`. That's because the canonical
particle attributes have a **fixed `Type` and `Kind`** the tool derives from the name and re-attaches on
build. The canonical set is:

> `Position` `Orientation` `Velocity` `Color` `Size` `LifeRatio` `LifeSpan` `FirstSpawnDelay`
> `Flux` `SpawnCount` `EmittedCount` `SpatialKey1` `SpatialKey2` `SpatialKey_Main` `ParentID`

Anything outside that set, or a canonical name used with an unusual type/kind, is spelled out in full —
`Name : Type = Flags kind Kind;` — so nothing is lost. (`= 0` flags are always omitted.)

### 7.2 `Kind` — the spawn-routing tag

`Kind` is the one payload attribute the **engine acts on structurally**. When a parent spawns a child, the
engine looks at each root payload's `Kind` to decide how to seed the newborn:

| Kind | Name | What the engine does with it |
|---|---|---|
| `1` | Position | seeds the newborn's position from this element, **transformed into the parent's frame** |
| `2` | Orientation | seeds + transforms the newborn's orientation |
| `3` | EmittedCount | the spawn machinery reads it as *how many* particles to emit |
| `0` | — | an ordinary inherited attribute (Velocity, Color, Size, LifeRatio, …) — copied straight through |

Because spawn transforms are driven off `Kind`, it is **load-bearing** — a `Position` element that lost its
`Kind = 1` would spawn children at the world origin instead of on the parent. cornsyrup derives `Kind` from
the canonical name and keeps it explicit for the rare off-table case (e.g. an `EmittedCount : i32 kind 0`).

### 7.3 Order is load-bearing — do not reorder fields

A field's **position** in an `event`/`root` block is its **element index**, and the code addresses payload
elements *by that index*, not by name:

```
// parent (evolve) — write element 1:
let key2 : i32 = Child.appendPayload(key1, 1, elem);
// child (init) — read element 1:
let pos : f32x3 = extractPayloadElementF3(1);
```

Both `1`s mean "the second field of this payload." Reorder the fields and `extractPayloadElement(1)` now
names a *different* attribute — a silent corruption. (This is not a convention: in the engine,
`extractPayloadElement(i)` compiles to a **positional index** into the payload array, verified at the
instruction level.) **Keep the field order exactly as decompiled.** It is the one thing about a payload you
must never rearrange.

### 7.4 `Flags`

The `= N` after a name is the raw `PayloadFlags` — packed source-authoring bits (read/write access, plus a
`0x1C00` group carried verbatim from the original `.pkfx` field). **The engine ignores nearly all of them:**
at load it reads exactly one bit — `0x20` (world-space transform), and only on a `Position`/`Orientation`
payload — and across the whole WC3 corpus that bit is never set (every effect is local-space). The rest are
bookkeeping the engine re-derives from the code. They round-trip for fidelity but encode no behavior you can
usefully edit; leave them as decompiled.

### 7.5 `root` vs `event`, and `root auto;`

- **`event NAME { … }`** always names itself; `event NAME;` is an empty kick. Event flags default to `1`;
  a rare non-default is `event NAME flags N { … }`.
- **`root { … }`** is the birth payload; **`root;`** is an empty root (the layer inherits nothing).
- **`root auto;`** — the root is **derived on build and dropped from the file**, so you don't author it.
  It always stands for the same fixed list, in this order:

  ```
  LifeSpan, FirstSpawnDelay, EmittedCount, SpawnCount, Flux, LifeRatio      // flags 8, EmittedCount kind 3
  ```

  Whether a root can be auto-derived comes down to *where its shape came from*:

  | Root kind | Source of its order + flags | Result |
  |---|---|---|
  | **Spawn-control** — `EmittedCount, SpawnCount, LifeSpan, FirstSpawnDelay, Flux, LifeRatio` | the layer's spawner, with a **fixed** order and flags every time | fully derivable → `root auto;` |
  | **Motion / appearance / spatial** — `Position, Velocity, Color, Size, …` | the **authored source graph** (not recoverable from the compiled `.pkb`) | stays written out in full |

  So `root auto;` is not a size hack — it marks the roots that are genuinely *baker-fixed*. The rest carry
  authored content (their order and flags were choices in the original `.pkfx`), so they legitimately live
  in the bundle. You may hand-write `root auto;` on any layer whose newborns need nothing but the
  spawn-control contract.

  **A custom payload needs a written root.** The derivation above is the whole of it, so a field a
  parent publishes under any other name — `Heat`, `TargetPos`, whatever your event declares — is *not*
  in an auto root, and every newborn reads it as **0**. Declare what the layer is born with:

  ```
  root {
      Heat : f32 = 1;             // flags 1; `kind K` if it is not the default
  }
  ```

  `build` warns when a layer with `root auto;` reads a field its parents publish but its root will not
  carry, naming the payload and the event it comes from. A parent that publishes more than its child
  reads is ordinary and stays quiet.

  **The one place `root auto;` is not byte-for-byte.** Some layers were baked with only the 2-element base
  `EmittedCount, SpawnCount` instead of all six. Which of the two a layer got is an authoring choice the
  bake **discards** — measured across the corpus, six-element and two-element roots are
  indistinguishable in the compiled `.pkb` (same trigger event in every case, same spawner call shapes,
  no code feature separating them by more than noise). Rather than leave the two-element ones
  hand-written forever, the decompiler marks them `root auto;` too and they come back with the full six.
  That is safe precisely where it is applied: such a layer reads no payload element (nothing can observe
  the extra entries or an index shift), its parent supplies none of them either, and
  six-unwritten-elements is what the structurally identical six-element layers already ship. Set
  `CFX_STRICT_AUTO_ROOT=1` to keep only the byte-exact markers, or `CFX_NO_AUTO_ROOT=1` to write every
  root out in full.

The **routing** of a kick event to its child layers is in the graph (§4.2); the **code** that fills and
reads these payloads is in `code.cfx` (§12). This file is only the shared **schema** the two rely on.

---


## 8. The layer coding language

`code.cfx` is the centre of the bundle: **one `layer <name> { … }` block per layer**, holding everything
about that layer — its structure (`properties`), its event payload schemas (`event` / `root`), its
editable simulation code (`init` + `evolve`), and its renderer input wiring (`bind`). This is the heart
of the format: rewrite a formula, rebuild, and behavior changes.

```
layer L0 {
    properties { … }       // the layer's structure: samplers, spatial layers, attributes, renderer links
    event Signal { … }     // the payload this layer's `Signal.kick(…)` carries        (§7)
    root { … }             // the payload a newborn of this layer receives at birth    (§7)
    fields { … }           // the particle fields its programs share, typed once      (§8.3)
    init { … }             // runs ONCE, when a particle is born (the "spawn script")
    evolve { … }           // runs EVERY frame, for every live particle (the "update script")
    bind rend0 { … }       // maps this layer's particle fields → a renderer's input slots
}
```

The order of the sub-blocks is free — only the order of fields *within* an event declaration is
load-bearing (§7.3). The decompiler emits them in the order above, schema before the code that uses it.

`evolve` may carry a scope hint: `evolve physics { … }` means the layer also needs the physics-scope
copy of the same program (see [The layer system](#9-the-layer-system)). You write the evolve logic
once; the build recompiles it into whichever scopes the layer needs.

### 8.1 The `properties` block

The layer's structure declaration: its scalar settings and its owned children (samplers, spatial layers,
attributes) and renderer links.

```
properties {
    UsageFlags = 3;
    RandomSeedModifier = 1;
    LODDistanceMin = -1;
    LODDistanceMax = -1;
    NeedsEvolveOnDeath;                 // bare = a `true` flag
    metaData;                           // compiler flag (below)
    child;                              // compiler flag (below)
    Renderers = [&rend5, &rend6];
    ConstantData = [(0,0,0,0), (4294967295,...), (1.0,1.0,1.0,1.0), (2.0,...)];

    sampler "__sampler_0" : Curve      = &sd26;
    sampler "EventStream" : EventStream = &sd0;

    spatial "…/Spatial Layer02" local "__spatialLayer_0" flags 1 cell 0.75 {
        payload "Position" : f32x3 = 7168;
    }

    attrib "__a_Game.Global.Spawning";
}
```

- **Scalar fields** — runtime settings like `UsageFlags`, `RandomSeedModifier`, `LODDistanceMin/Max`.
  A boolean-`true` flag renders as its bare name with a trailing `;` (`NeedsEvolveOnDeath;`). Always-`[]`/`&null`
  placeholder fields are hidden (reconstructed on build).
- **Compiler flags** `metaData;` / `child;` — two bare flags the compiler sets that the code doesn't
  reveal: `metaData` = the layer allocates a `self.metaData` scratch field; `child` = it is spawned by
  another layer (it has a `ParentID`). (These used to live in a separate `fields.cfx`.) A layer that
  calls `self.kill` gets `self.metaData` whether or not it says `metaData;`: the kill bit lives in it.
- **`NeedsEvolveOnDeath`** is set by the build when `evolve` kicks, triggers, inserts or kills, as
  the baker does, unless the layer says `NeedsEvolveOnDeath = false;`; it is dropped from a layer
  that does none of these anywhere. The game runs `evolve` on a dying particle only under this flag,
  and that run is the one that sees it die, so with `= false` a kick at death
  (`trigger(self.lifeRatio >= 1.0, …)`) never fires; `build` warns of it.
- **`ConstantData`** — the layer's baked constant pool; clean float bit patterns render as floats
  (`0x3F800000` → `1.0`), the rest stay raw (`4294967295` = `0xFFFFFFFF`).
- **`Renderers = [&rendN]`** — links into `renderers.cfx`.
- **`Events = [];`** — the layer's event list, which `build` fills from the layer's `event` blocks
  (§7). `decompile` writes the line, and it is not needed: a layer that declares events gets them
  without it. (It used to be: without the line the layer lost its events while its kicks still
  compiled, and the game dropped every kick.) A program that kicks an event its layer does not
  declare is refused, a `needs` line typing it `particleEvent` or not: the game binds an event by
  its name among the layer's events. A kick the `graph` routes to no layer warns.
- **`sampler "Name" : Kind = &sdN`** — a named sampler bound to data in `samplers.cfx`.
  `Kind` ∈ `Curve`, `Shape`, `Turbulence`, `EventStream`. The code references it by `Name`. A
  Shape's or a Texture's usage flags are the calls the code makes on it (`samplePosition` 1025,
  `sample` on a Texture 4), and `build` works them out; an older bundle's `usage F` is still read,
  and replaced by what the calls give.
- **`spatial "…" local "…" flags F cell C { payload "N" : Type [= flags] }`** — a spatial layer (a
  neighbour-query acceleration grid; see [Events/Spatial](#115-spatial-layers)).
- **`attrib "Name";`** — the layer's local binding of an effect attribute (read in code by the
  `__a_Name` external, or by a `Wc3.Attributes.…` constant — §8.9). Just the name: everything
  else is a **mirror** of the effect's own `attributes { … }` declaration (§4.1) and is reconstructed on
  build — type, `default`, `min`, `max`, `semantic`, and the `HasMin`/`HasMax`/`UseSlider` bits of the
  stored flags. The one bit the layer adds is *does this layer's code read the attribute*, which its
  program's externals answer.
  The long form `attrib "Name" : Type [default V] [min V] [max V] [flags F] [semantic S]` is still
  read, and is what the decompiler writes when the effect declares no matching attribute — then there
  is nothing to mirror. Its `Type` must be the effect's, and a program may read only an attribute
  the effect declares: the game finds the layer's among the effect's, and reads one it does not find
  past the end of the attributes' data, which crashes it. `build` refuses both. A **standard**
  attribute bound in the short form counts as declared even when `effect.cfx` leaves it out: the
  build declares it (§4.1).

### 8.2 The `bind` block

Maps the layer's particle fields to a renderer's input **slots** — the field wiring that used to be a
`Streams` list in `renderers.cfx`, now placed beside the code that produces those fields.

```
bind rend0 {
    "n21__Position" -> Position;      // this field  →  the renderer's Position input
    "n21__Size"     -> SizeScale;
    "n21__Enabled"  -> Enabled;
    "n21__Color"    -> Color;
    "Rotation_…"    -> Rotation;
}
```

- `bind <renderer>` names the renderer (by the same identifier used in `renderers.cfx`).
- Each `"field" -> Slot;` line maps one of the layer's particle fields to a renderer input slot. A
  line without `->` is an error.
- A slot is a **standard slot** — `Position`, `SizeScale`, `Enabled`, `SortKey`, `Axis0`, `Axis1`,
  `Rotation`, `SizeScale2`, `Axis`, `SelfID`, `ParentID`, `MeshID`, `Orientation`, or its number
  (`-> 8` is `-> Axis`) — or an **extra input** the renderer's material declares, named by its field
  name: `Color`, `TextureID`, `TextureU`, `Cursor`, `Range`, `Volume`, `Velocity`, `UVOffset`,
  `UVScale`, `UVRotate`, `EmissiveColor`, `Input0`…`Input3`. An extra input takes `@<semantic>` (100
  or more) when it is not its default (`TextureID@102`). Any other name is an error: it used to build
  as an extra input no renderer reads, so `-> Width` for `-> SizeScale` built a ribbon with no width.
- One renderer's extra inputs need distinct semantics: the game finds an extra input through its
  semantic, and of two on one it finds one. Written without `@`, they are numbered apart — `TextureID`,
  `TextureU` and `Cursor` all default to 101, and the second takes the lowest free semantic. Two
  written with the same `@`, or one input bound twice, are refused.
- Each input is bound to a field of the type the game reads it as: a Billboard's `Position`, `Axis0`
  and `Axis1` are `f32x3`, `SizeScale` `f32` and `SizeScale2` `f32x2` (a Ribbon's `Position` and
  `SizeScale` the same); `Color` is `f32x4`, and `TextureID`, `TextureU` and `Cursor` are `f32`.
  Another type is refused: the billboarders read a missing stream, and crash, and the draw layer
  never reads an extra input of another type.
- An extra input belongs to a material: `TextureU` is a Ribbon's (`CustomTextureU`), `Range` a
  Light's, and `build` refuses one on a renderer whose material does not have it. `UVOffset`,
  `UVScale`, `UVRotate`, `EmissiveColor` and `Input0`…`Input3` build with a warning: Warcraft III
  reads none of them.
- **A Ribbon** must bind `SelfID` and `ParentID`: the game forms a strip by sorting a draw's
  particles on `ParentID`, then `SelfID`, and a ribbon without them is refused. Its axis is `Axis`;
  `Axis0` and `Axis1` are a Billboard's, which a Ribbon never reads, and are refused there (as `Axis`
  is on a Billboard). `CustomTextureU = true;` and a `TextureU` input go together; one without the
  other warns (§6.8).
- **A Billboard** must bind `Position`, and the size it reads: `SizeScale`, or `SizeScale2` when it
  sets `EnableSize2D`. Without them, or with no `bind` at all, it draws nothing, and is refused.
  Under `EnableSize2D`, bind `SizeScale` too, a field holding each particle's larger half size: the
  game bounds a page of particles by `SizeScale`, and without it a particle whose centre leaves the
  screen vanishes while its quad is still on it; `build` warns.
- **A Billboard's `Enabled`** should be written the constant `true`. The game sizes each page's
  vertices by its enabled particles but writes every particle's, so a page with a hidden particle
  writes past its range; `build` warns when `Enabled` is computed, `false`, or never written. Hide a
  particle by giving it a size of 0 instead.

### 8.3 The `needs` block

Each program begins with a `needs` block declaring the external values it reads or writes, with their
types:

```
needs {
    "PrevAge"    : f32;
    "EventAccum" : i32x2;
}
```

In practice that is all a real block holds, because most entries are **derived** — see the note at
the end of this section. Written out in full, the same block is:

```
needs {
    "self.lifeRatio" : f32;              // derived — an engine constant
    "PrevAge"        : f32;
    "EventAccum"     : i32x2;
    "scene.dt"       : f32;              // derived — an engine constant
    "Signal"         : particleEvent;    // derived — an event this layer declares
    "EventStream"    : samplerEventStreamC;  // derived — a sampler this layer declares
}
```

`needs` names an external **register** (a particle field, a scene global, a context, a sampler, an
event). The name's family tells you what it is:

| Name pattern | Kind |
|---|---|
| `self.X` | a per-particle intrinsic — `self.lifeRatio`, `self.invLife`, `self.metaData` (scratch) |
| `scene.X` | a scene global — `scene.time`, `scene.dt` |
| `Position`, `Rotation`, `Color`, `Size`, `Velocity`, `Orientation`, … | a **particle field** (evolved per-particle state; renderer inputs reference them as `n{id}__Field`) |
| `internal_HHHHHHHH` | a compiler-generated field that persists between frames (a hidden state variable) |
| `__sampler_N` | a sampler handle (bound in the layer's `properties`, §8.1, to data in `samplers.cfx`) |
| `__spatialLayer_N` | a spatial-layer handle |
| `__a_Name` | an **effect attribute** (declared in `effect.cfx`, §4.1) — the ten the game drives are written as constants instead (§8.9) |
| `Signal`, `__e_Child`, `__e_OnSpawn`, … | an **event** the program kicks/generates into |

> **Contexts are implicit.** The engine handles `ParticleContextS`/`I`/`N`, `RandContext`, and
> `SceneContext` are auto-supplied to the calls that need them, so they never appear in `needs` and you
> never load them (`let v1 = ParticleContextI;` is gone). The compiler re-derives which contexts each
> program needs from its calls and re-inserts them when building the `.pkb`.

> **Most entries are optional**, because the bundle already says what they are and `build` puts them
> back. Five kinds are derived:
>
> | Entry | Derived from |
> |---|---|
> | `scene.dt`, `scene.time`, `self.invLife`, `self.lifeRatio` | the engine — those four are all it exposes |
> | `Wc3.Attributes.…` (§8.9) | the engine's own attribute table |
> | an event the layer declares | `event NAME;`, a few lines up |
> | a sampler the layer declares | `sampler "N" : Kind = &sdX;` plus the descriptor in `samplers.cfx` |
> | an effect attribute (`__a_Name`) | the `attributes { … }` declaration in `effect.cfx` (§4.1) |
>
> What is left is the **stream fields**, and each keeps its line: the `needs` block is the only place
> a layer field's type is written down. Declaring a derived entry anyway is legal and changes
> nothing — except that a type disagreeing with the declaration it would be derived from is taken at
> its word, because a program that loads a value at a different type is telling you something the
> derivation cannot.

**The layer's `fields` block.** A layer declares the fields its programs share once, beside them,
with the same entries:

```
layer L1 {
    root;
    fields {
        "PrevAge"    : f32;
        "EventAccum" : i32x2;
    }
    init { … }
    evolve { … }
}
```

Each program then declares the fields its code names, **in the block's order** — after the entries
of its own `needs`, when it has one. That order is load-bearing as a `needs` block's is: it is the
order of the program's external table in the `.pkb`. A field counts as named where the code writes
it (`PrevAge`, `ext "odd name"`), not as a member after a `.`. `decompile` writes every layer this
way: in every layer of the game corpus the programs' lists agree on one order, and only two
programs keep a `needs` of their own, for a field they declare and never use.

**A field's name.** A field is called by the name its entry gives it, and the build stores that
name. The game binds each program's externals to the layer's fields by it, within the layer, and a
renderer finds a field by its place in the layer, so any word the layer does not already mean
something else by will do. The baker chose the names a `.pkb` stores — `n23__Position` (the editor's
node, then the input), `Rotation_540603fd` (a hash), `internal_4f9baf59` (a CRC of a name the binary
no longer holds) — and `decompile` calls each one by a word instead, in one convention:

| What | Case | Example |
|---|---|---|
| a field a renderer reads (one a `bind` line feeds) | `p` + PascalCase | `pPosition` |
| any other field: the particle's own state | `s` + PascalCase | `sSpinAccum` |
| a `let` | snake_case | `life_ratio` |
| a layer, a renderer, a sampler | PascalCase | `FlareSimpleBW`, `FlareSimpleBWBillboard`, `Sampler2` |

```
layer L3 {
    fields {
        "pPosition" : f32x3;    // stored as n23__Position
        "sTimer"    : f32;      // stored as internal_4f9baf59
    }
    evolve {
        let ratio_since_stop = life.ratio_since_stop(timer = sTimer, rate = inf);
        sTimer = ratio_since_stop;
    }
    bind L3Billboard {
        "pPosition" -> Position;
    }
}
```

Only `decompile` follows the convention; a bundle may call anything by any name the language allows,
and `build` checks none of it.

One thing `build` does read off a field's name: whether the engine carries the field into the
parent's frame when a child is spawned. A field whose word starts `Position` is moved, rotated and
scaled with the parent; one that starts `Axis` or `NormalAxis` is rotated and scaled. The word is the
name itself, the part after an editor node (`n7__Position`), or the part after the `p` of a field a
renderer reads (`pPosition`); `sPosition`, like `position`, is the particle's own state and stays
where it is. In every game effect each field the baker carries is a renderer's, so the convention
keeps them; where a decompiled field's renderer and its frame disagree, the frame chooses its prefix.

The name is the field's from then on: a rebuild stores `pPosition`, and the effect works as the
original does. Every field takes the convention, whatever it was stored as; its word is the input
after `n<id>__` (or `n<id>_<id>__`), the word before a hash, for an `internal_…` the library parameter
the programs pass it to (`timer`, `velocity`), when there is just one and its name is a word, not
`a`, and for any other name the name itself (`velocity` is `sVelocity`, and a name already in the
convention stays as it is). An `internal_…` no parameter names is called by what the programs do with
it, its first fitting role:

| Word | The field |
|---|---|
| `spawn_carry` | a rate-driven emitter's carry: stored from a `generate` result's `.xy`, and handed back to that `generate` as its accumulator |
| `prev_E` | last frame's value of element `E`: stored in `evolve`, and sent as `E`'s `prev` beside a different `cur` |
| `root_E` | a copy of element `E` the particle was born with: `extractPayloadElement…(i)` stored in `init` only |
| `birth_time` | `scene.time` stored in `init` only |
| `rand_W`, `init_W` | a value set once in `init` whose every read ends in one place, a store to field `W` or an element `W`; `rand_` when it draws a `rand` |

A field handed to a library call in `evolve` is not set once (a `&` parameter writes it), and a value
read in two places has no role; the word a role gives is the field's after its prefix
(`sSpawnCarry`, `sPrevColor`, `sBirthTime`). A name the programs already say, or one the layer
declares something else by — an event, a sampler, a spatial layer, an attribute — gets a number
(`sColor`, `sColor2`); a parameter's word gives way instead, to the field's own name. A field stored
under an engine field's name (`SelfID`) keeps it. `CFX_NO_NAMES` keeps every stored name.

A layer's sampler is called by its stored name in PascalCase (`__sampler_2` is `Sampler2`,
`colorCurve` is `ColorCurve`), and so is its data in `samplers.cfx`, after the layer's name
(`FlareSimpleBWSampler2`). A renderer is named after the file it draws and its geometry
(`FlareSimpleBWBillboard`), the layer that draws with it after the file alone (`FlareSimpleBW`), and a
renderer that draws no file after its layer (`L4Light`).

Renaming a field renames it everywhere the layer names it: its `fields` or `needs` entry, its
programs' code (also as `ext "…"`) and the left of a `bind` line. A member after a `.`, a call's
argument keyword (`timer = …` inside the parentheses), an `emit` or `insert` block's element
(`Size = v3;`) and its `kind`, an event's payload names and a renderer slot (`-> Position`) are other
names, and stay; nor does a program name a field by sending an element spelled like it. Mill's Layer
form renames a field this way, in its **fields** panel.

> A layer once kept the stored names in a `names { … }` block, so that a rebuild stored them again.
> Nothing the game does reads them, so the block is gone: `build` refuses one, and deleting it is the
> fix. Its words become the fields' names, and the effect works the same.

### 8.4 Statements

Four statement forms, and the `emit` and `insert` blocks:

```
let v3 : f32 = effect.age();      // bind a computed value to a name (a temporary)
v3 = v3 * 2.0;                      // reassign that name
PrevAge = v3;                       // STORE: write an external/particle field
Signal.kick(v7);                    // a void call (a side-effecting statement)
Child.emit(gen) { Size = v3; }      // send an event with its elements by name (§12.1)
__spatialLayer_0.insert(p) { Position = p; }  // into a spatial layer, payloads by name (§11.5)
```

- **`let NAME : T = EXPR;`** — a temporary. The type annotation is on the left (like Rust). Names are
  cosmetic; they exist to share sub-expressions. A name may not be a **reserved word** — `let`,
  `store`, `do`, `as`, `void`, `true`, `false`, `nan`, `inf`, `neg`, `lnot`, `select`, `swz`, `ctor`,
  `reint`, `conv`, `transmute`, `reg`, `call`, `raw`, `ext` — and neither may a function parameter.
  A field that happens to be called one is read quoted, as `ext "raw"`.
- **`NAME = EXPR;`** — **reassign a local**. Every `let` is mutable; there is no `mut`. See below.
- **`Target = EXPR;`** — a store to a particle field / external named in `needs`.
- **`Target.<comps> = EXPR;`** — a **swizzle store**: write only the named lanes of a vector external
  (`velState.x = speed;`, `velState.xy = v2;`), keeping the other lanes. The untouched lanes are read
  from the external's current value, so consecutive component writes compose as expected. The RHS is a
  scalar for a one-lane write, a vector for a multi-lane one. Locals take the same form
  (`v.z = v.z - 9.8 * scene.dt;`) and rebind rather than store.
- **`EXPR;`** — a bare call whose result is unused (e.g. `kick`, `self.kill`).

#### Reassigning a local

A `let` names a **value**, not a storage cell, and a program has no branches — so reassignment is
not mutation, it is a new binding of the same name. Statements already written keep the value they
captured; every LATER read sees the new one. That is SSA, and the compiler does the renaming.

The chief use is threading a value through a sequence of calls, which is otherwise a ladder of
throwaway names. Both of these compile to the same bytecode:

```
let k : i32 = Death.initPayload(0, gen);        let k0 : i32 = Death.initPayload(0, gen);
k = Death.appendPayload(k, 0, pos);             let k1 : i32 = Death.appendPayload(k0, 0, pos);
k = Death.appendPayload(k, 1, vel);             let k2 : i32 = Death.appendPayload(k1, 1, vel);
Death.kick(k);                                  Death.kick(k2);
```

Two things to know:

- **Keep the annotation on the `let`.** A reassignment carries no `: T` of its own, so the
  declaration's type is what an overloaded call on the right-hand side resolves against. Dropping it
  from `let k : i32 = …` changes which `appendPayload` overload is selected — and changes the bytes.
  With no annotation anywhere, `rand` takes its width from its bounds: `rand(#f32x3(…), #f32x3(…))`
  is three independent draws, `rand(0.0, 1.0)` is one. Three draws over one scalar range is
  `let r : f32x3 = rand(0.0, 1.0);`.
- **A local may shadow a field.** Reads already prefer the local, and so does assignment: after
  `let Position : f32x3 = …`, `Position = v;` rebinds the local and never writes the field. Give the
  temporary a different name if you meant the store.

A **function parameter is not a local**. It is the caller's lvalue, so a write to one stays a
write-back (§13.4) — that is what makes `fn integrate(position: &f32x3, …)` work.

### 8.5 Expressions

| Form | Example | Meaning |
|---|---|---|
| literal | `42`, `3.14`, `-inf`, `true`, `void` | constants |
| exact-bits literal | `0.1@0x3DCCCCCD` | a float whose decimal wouldn't reparse exactly |
| vector constant / ctor | `#f32x3(1, 0, 0)`, `#f32x3(0, y, 1)` | inline vector — a constant when all components are literals, otherwise a constructor from the given expressions |
| reference | `PrevAge`, `v3`, `scene.dt` | an external, input, or `let`-name |
| binary op | `v3 <= v10`, `a * b`, `x & y` | infix operators (see below) |
| unary | `-x`, `neg(x)`, `!x`, `lnot(x)` | negation / not (logical on a bool, the bitwise complement `~x` on an int; the result keeps the operand's type) — prefix `-`/`!` work on any expression (`-radians.cos(a)`, `-(a + b)`), and the decompiler prints them; a literal is negated as `-(1.0)`, since `-1.0` is a negative literal |
| math func | `frac(x)`, `min(a, b)`, `lerp(a, b, t)` | built-in math (arity picks the intrinsic) |
| select | `select(cond, tVal, fVal)` | branchless conditional (`cond ? tVal : fVal`) |
| method call | `EventStream.generate(v5, v2, v3, 0.0, scene.dt)` | an object builtin |
| free call | `rand(0.5, 0.8)`, `hsv2rgb(v)` | a free-function builtin |
| swizzle | `v6.xy`, `v7.xxxx` | component selection / broadcast |
| vector ctor | `ctor<f32x4>(a, b, c, d)` | build a vector from parts |
| bit cast | `transmute::<orientation>(x)` | Rust-style **bit reinterpretation** (reads the same bits as another type) — contrast `as`, which converts the value |
| cast | `x as f32`, `n as i32x2` | Rust-style **value conversion** — binds tighter than every binary operator (`a + b as f32` is `a + (b as f32)`). The game converts only between `f32` and `i32`, from a `bool` to `i32` or `f32`, and from a byte to `i32`; any other cast is refused. For a `bool`, compare: `x != 0` |

**Operators** (infix, always with a computed type):

```
+  -  *  /  %        arithmetic
<< >> & | ^          bitwise / shift
<  <= >  >= == !=    comparison (→ bool / boolN)
&  |                 also logical AND/OR on bools
```

Comparisons and `select` are how the code branches — there is no `if`. For example, the standard
"clamp lifetime to a window" idiom:

```
self.lifeRatio = select(v9 & v3 <= v10, v8, 1.0);
//               keep lifeRatio if (running AND age ≤ duration), else set to 1.0 (= die)
```

**An int beside a float.** Where operands take one number type, an `int` beside a `float` is
promoted to float, as `as f32` would, and the answer is a float: `Velocity * 2` is
`Velocity * 2.0`, `k * x` for an `i32` `k` is `(k as f32) * x`, and `min(k, 1.5)` is
`min(k as f32, 1.5)`. That is the two operands of an arithmetic operator or a comparison; every
argument of a math function (`min`, `max`, `clamp`, `lerp`, `within`, `step`, `dot`, …); the two
values of a `select`; and the arguments an engine builtin's signature takes as floats (`rand`'s two
bounds). A bitwise or shift operator (`& | ^ << >>`) has no float form, and neither have the
arguments a builtin takes as ints (`buildPayloadElement`'s), so an int and a float there is an
error that says which cast to write. A builtin's float argument takes a float with no float beside
it too: `rand(0, 1)` is `rand(0.0, 1.0)`, as the baker converts it (a payload's element values,
`buildPayloadElement`'s and `appendPayload`'s, take any number type and keep theirs).

**Types, the way PopcornFX checks them.** `build` type-checks each program the way PopcornFX's
baker checks a script, and refuses what the baker refuses, at the line: a vector stored to a field
of another width (`Size = Velocity;`: write `Velocity.x`); a store to an engine value the game does
not let a program write (`scene.dt`, the `scene.*` and `view.*` values, a sampler, an event, an
attribute); `+ - * / %` on two bools and `-` on a bool; `& | ^` on floats and `<< >>` on anything but
ints; two operands, or two arguments of a math function, of different vector widths (a scalar beside
a vector is fine); a `select` whose condition is neither one lane nor as wide as its values; a
constructor given more or fewer lanes than it has (`#f32x3(a, b)`); a swizzle of a lane its source
does not have (`v.w` on an `f32x3`, `s.y` on a scalar); a `transmute` to another lane count. Where
the baker converts, `build` converts the same way: a value stored to a field of another lane type is
converted (`as f32`, `as i32`; into a `bool`, `x != 0`, with a warning), a scalar stored to a vector
is repeated (`.xxx`), a bool beside a number is converted to it, an int or bool argument of a math
function with no int form (anything but `abs`, `sign`, `min`, `max`, `clamp`) is converted to a
float, a scalar beside a vector in a math function or a `select` is repeated, a float or int `select`
condition is `x != 0` (with a warning), and `!` on a float is `!(x != 0.0)`. Two things stay CFX's
own: `!` on an int is the bitwise complement, and a `let` annotation does not convert — the value
keeps its own type. `docs/engine/type-checks.md` has the baker's rules and what the game does with
each refused case.

**Constant folding.** Sub-expressions made entirely of literals are evaluated at build time, so
`1.0 + (3.0 * 4) * rcp(2)` compiles to a single `7.0` — no runtime ops. A mixed `int`/`float` operand
(`3.0 * 4`) promotes the int to float here too. Folding covers `+ - * /`, bitwise, comparisons, casts, and the
exactly-rounded intrinsics (`rcp`, `sqrt`, `abs`, `neg`, `floor`, `ceil`, `frac`, `saturate`, `min`,
`max`); the approximate ones (`radians.sin`/`cos`, `exp`, `log`, `fast.*`) are left for the runtime so
their low bits match the engine.

A **literal can be swizzled**, which is how a scalar is broadcast to meet a vector: `0.5.xxx` is
`#f32x3(0.5, 0.5, 0.5)`, and `2.0.xy` is `#f32x2(2, 2)`. Spaces are never required around an
operator — `1.0-0.25` is a subtraction, not a malformed number.

### 8.6 Types

Scalar/vector value types use the **Rust spelling**: `bool`, `boolx2..4`, `i32`, `i32x2..4`, `u32`,
`u32x2..4`, `f32`, `f32x2..4` (and `f64`). These map 1:1 to the engine's own names — `f32x4` is
PopcornFX's `float4`, `i32x2` its `int2` — and either spelling is accepted on build.

Opaque handle types you'll see in `needs` and `let`:

| Type | What it is |
|---|---|
| `particleEvent` | an event object (target of `kick`/`generate`/`initPayload`) |
| `samplerCurve1C`/`3C`/`4C` | a curve sampler (1/3/4 channels) |
| `samplerShape_3C` | a shape sampler |
| `samplerTurbulenceN` | a turbulence sampler |
| `samplerEventStreamC` | an event-stream sampler |
| `SpatialLayerType` | a spatial-layer handle |

### 8.7 A complete evolve program, annotated

```
evolve {
    needs { … }
    let v2 : f32  = PrevAge;                         // read persisted state
    let v3 : f32  = effect.age();                    // seconds since the effect started
    let v5 : i32x2   = EventAccum;                       // the emission accumulator
    let v6 : i32x3   = EventStream.generate(v5, v2, v3, 0.0, scene.dt);  // how many to emit this frame
    PrevAge    = v3;                                   // advance state for next frame
    EventAccum = v6.xy;
    let v7 : i32  = Signal.initPayload(0, v6);          // park the count for the kick
    Signal.kick(v7);                                    // fire the event → children spawn
    let v8 : f32 = self.lifeRatio;
    let v9 : bool  = effect.isRunning();
    let v10 : f32 = EventStream.duration();
    self.lifeRatio = select(v9 & v3 <= v10, v8, 1.0);   // stop emitting when the timeline ends
}
```

### 8.8 Reading renderer and sampler properties

A layer's renderer and sampler settings are readable from its code. Write the owner's handle and
the dotted property name exactly as `renderers.cfx` / `samplers.cfx` spell it:

```
let frames : f32 = (rend0.Atlas.SubDiv.x * rend0.Atlas.SubDiv.y - 1) as f32;
n21__TextureID = frames * self.lifeRatio + 1.0;
```

**There is no runtime path, and there does not need to be one.** The script VM's world is externals —
particle fields, `scene.*`, sampler handles, events; a renderer is a *draw-time* consumer the VM never
addresses. So a property reference is **not a load**: it is a literal the compiler substitutes, after
which ordinary constant folding (§8.5) collapses whatever surrounds it. The example above compiles to
`n21__TextureID = 63.0 * self.lifeRatio + 1.0;` — one constant, no atlas arithmetic per particle, and
**zero new bytecode**. The feature is invisible in the blob.

That is also why it is read-only: a write would have to reach back into `renderers.cfx`, which is not
something compiling a program can do.

What it buys you is that derived constants stop being copied by hand. Re-tile the texture to
`Atlas.SubDiv = (2, 2)` and the same source recompiles to `3.0`.

#### What you can name

| Owner | Example |
|---|---|
| a renderer handle (as in `renderers.cfx`) | `rend0.Atlas.SubDiv`, `rend0.BillboardingMode` |
| a sampler handle (as in `samplers.cfx`) | `sd17.Radius`, `sd17.ShapeType` |
| a sampler's **local name** (as declared in the layer's `properties`, §8.1) | `__sampler_2.Strength`, `__sampler_0.Interpolator` |
| a **`const &` parameter** of a function (below) | `local_rend.Atlas.SubDiv` |

A trailing swizzle works as it does anywhere else, because the result is an ordinary vector constant:
`rend0.Atlas.SubDiv.x`, `sd17.Position.xz`. An enum's names are not accepted in code: a name such
as `PlaneAligned` in a program is an ordinary external, not the enum's value.

A handle is whatever `renderers.cfx` calls it. `rend0` is only what a decompile *generates*; rename it
and the new name is the one to use everywhere — `Renderers = [&TrailParticle]`, `bind TrailParticle`,
`TrailParticle.Atlas.SubDiv`, and as a `const &Renderer` argument.

**The bare shorthand.** In a layer with exactly **one** renderer, the owner may be omitted —
`let soft : f32 = SoftParticles.SoftnessDistance;`. With two or more renderers this is an error that
lists them; silently picking the first would be a trap, since `bind rend0` and `bind rend1` are
visibly different things. The shorthand is tried only after every other name resolution fails, so it
can never shadow a `let`, an external, or a function.

#### What is readable, and what is not

Every property that is not a string is readable, as the type `renderers.cfx` gives it — floats, ints
and enum selectors (`BillboardingMode` is an `i32`), feature toggles and bool fields (`bool`), and
int/float tuples. Two things are deliberately not:

- **Texture and asset paths** are strings, and the code language has no string values. Reading
  `Diffuse.DiffuseMap` is an error pointing at `sample()`, which is probably what was wanted.
- **Curve `keys` and an EventStream's `Times[]`** are the sampler's *payload*, not properties of it —
  they are what `sample()` and `generate()` consume at runtime.

A typo is an error that lists what the owner does have (`rend0 (Billboard) has no property
'Atlas.SubDvi' (has: …)`), or names the property meant when only the case is wrong (`… has no
property 'Atlas.subdiv' (did you mean 'Atlas.SubDiv'?)`), so an unreadable property is a build error
and never a silent zero.

#### `else` — the unset-property fallback

A property the effect never set has no value in the `.pkb` at all: the engine takes it from the
`.pkma` material, which is not part of a bundle. Those read as **zero** — the same thing `cornflakes`
binds — and `else` supplies something better where you know better:

```
let soft : f32 = rend0.SoftParticles.SoftnessDistance else 0.6;
```

`else` wins **only** when the property is genuinely absent; a real stored setting always beats the
fallback, so adding one can never override the bundle. It is resolved at compile time like everything
else — not a runtime branch — and the compiled code contains exactly one of the two constants. `else`
is permitted only on a property read.

Feature toggles need no fallback: a toggle carries a value only when it is enabled, so an unset one is
genuinely `false`. That is complete information, not an assumption.

#### `const &` parameters — passing a renderer to a function

A `functions.cfx` function (§13) can take a renderer or sampler **handle**, and its property reads
resolve against whatever each call site bound:

```
fn selectTextureIdOnAge(local_rend : const &Renderer) -> f32 {
    needs { "self.lifeRatio" : f32; }
    let age    : f32 = self.lifeRatio;
    let factor : f32 = (local_rend.Atlas.SubDiv.x * local_rend.Atlas.SubDiv.y - 1) as f32;
    factor * age + 1.0
}
```

```
n21__TextureID = selectTextureIdOnAge(rend0);      // → n21__TextureID = 63.0 * self.lifeRatio + 1.0;
```

- The argument must **be** a handle (`f(rend0)`, `g(__sampler_2)`) — an expression has nothing to
  resolve, and is an error.
- Each call site gets its own constants: `…(rend0)` and `…(rend1)` inline to different literals from
  the one function.
- A read through the parameter takes an `else` like any property read
  (`r.SoftParticles.SoftnessDistance else 0.6`), decided for each call site's renderer.
- A `const &` parameter may be **passed on** to another function's `const &` parameter; the handle
  travels the way a `&T` reference does.
- `const &T` is a *different* form from the `&T` of §13.4: that one is a mutable lvalue reference
  that writes back, this one is an immutable compile-time handle. Writing through it is an error, and
  `Renderer` / `Sampler` are meaningful only behind `const &` — there is no by-value renderer.

`stdlib/life.cfx` ships `life.select_texture_id_on_age` / `life.select_texture_id_on_inv_age` built on
this.

### 8.9 Engine attribute constants

An attribute (§4.1) is a value the **host game** writes into the effect every frame; a program reads
it back as an external named `__a_<ExportedName>`. Warcraft III writes exactly ten of them, and each
has a constant you name directly:

| Constant | Attribute | Type | What the game puts there |
|---|---|---|---|
| `Wc3.Attributes.LifespanMultiplier` | `Game.LifespanMultiplier` | `f32` | MDX emitter lifespan scale (animatable) |
| `Wc3.Attributes.EmissionRateMultiplier` | `Game.EmissionRateMultiplier` | `f32` | MDX emission-rate scale (animatable) |
| `Wc3.Attributes.SpeedMultiplier` | `Game.SpeedMultiplier` | `f32` | MDX speed scale (animatable) |
| `Wc3.Attributes.ColorMultiplier` | `Game.ColorMultiplier` | `f32x4` | emitter colour × alpha, RGBA |
| `Wc3.Attributes.TeamColor` | `Game.TeamColor` | `f32x4` | the owning player's colour |
| `Wc3.Attributes.TargetPosition` | `Game.TargetPosition` | `f32x3` | lightning-bolt destination |
| `Wc3.Attributes.Scale` | `Game.Scale` | `f32` | emitter scale (MDX flag `0x40000`) |
| `Wc3.Attributes.Weather.TileCenter` | `Weather.TileCenter` | `f32x3` | weather tile centre |
| `Wc3.Attributes.Weather.Size` | `Weather.Size` | `f32x2` | weather tile extent |
| `Wc3.Attributes.Weather.EmissionRate` | `Weather.EmissionRate` | `f32` | weather emission rate |

```
n34__Position = v5 + Wc3.Attributes.Weather.TileCenter;
rgba          = v3 * Wc3.Attributes.TeamColor;
```

The constant **is** the external — the two spellings compile to the same reference, and the raw
`__a_Game.TeamColor` still parses. Two things follow from the engine fixing the type:

- **No `needs` entry.** Like `scene.dt`, the name settles the type, so the line is optional in a
  layer program and the decompiler leaves it out. (Writing it is still fine, under either spelling.
  A `functions.cfx` body still declares it — §13.1.)
- **A typo is a build error**, not a silent zero: `Wc3` is a reserved namespace, so
  `Wc3.Attributes.Sacle` names nothing and says so, instead of reading an attribute no host writes.

The layer must still **bind** the attribute — `attrib "__a_Game.TeamColor";` in its `properties`
(§8.1) — and the effect must declare it: `"Game.TeamColor";` in `effect.cfx`'s `attributes`, or
nothing at all, since the build declares a standard attribute a layer binds and the effect leaves
out (§4.1). Those lines name the declaration rather than reference it, so they keep the exported
spelling.

**The other names get no constant, deliberately.** `CParticleEffect::GetAttributeID` matches by exact
string compare, so a name that is one token off binds to nothing at all. The corpus declares other
attribute names too, and those outside the table — `Size_Multiplier`, `Wind`, `EjectionSpeed`, and
near misses like `Game.EmissionRate` and `Game.LifetimeMultiplier` — are effect-local values no
engine code ever writes. They stay ordinary externals with an ordinary
`needs { "__a_Wind" : f32x3; }` line, which is exactly what they are.

---

## 9. The layer system

An effect is a tree of **layers**. Each layer is a *medium* — a pool of particles that share the same
scripts, fields, samplers, and renderers. The graph (`effect.cfx`) wires layers together with events:
a layer emits events, and child layers are spawned by them.

### 9.1 Per-particle lifecycle

Every frame, for each layer's page of live particles, the engine runs (in this order):

1. **Update life:** `lifeRatio += dt * invLife`  (`invLife` = 1 / lifetime).
2. **Kill dead particles:** any particle with `lifeRatio ≥ 1.0` is removed **before** its script runs
   again. A newborn starts at `lifeRatio = 0`.
3. **Run `evolve`** for every remaining slot.

So a particle lives for `1 / invLife` seconds. Two consequences you can exploit in code:

- **Instant death:** set `self.invLife = inf` (via `scene.dt * inf`, etc.) and the particle lives for
  exactly one frame — an "emit one batch, then die" spawner. The idiom:
  ```
  let v3 : f32 = saturate(v1 + select(!running, scene.dt * inf, 0.0));
  self.kill(v3 == 1.0);
  ```
- **The death frame still ticks.** `lifeRatio` is updated *inside* the script, and the kill check runs
  *after*, so the frame where `lifeRatio` crosses `1.0` still executes `evolve` once. Logic that
  depends on `self.lifeRatio >= 1.0` (final-frame emission, cleanup) sees the crossing.

`self.kill(cond)` is an explicit kill switch: it marks the particle dead when `cond` is true. The
layer needs nothing else for it: the build gives it the `self.metaData` field the kill bit lives in.

### 9.2 `init` vs `evolve`

- **`init`** runs once, at birth. It sets initial field values (position, color, rotation, lifetime).
  It reads the spawn **payload** delivered by the parent (see [Payloads](#12-payloads)) and draws the
  per-particle randoms. Newborns get an **independent RandState**, so `rand()` in `init` gives each
  particle its own values.
- **`evolve`** runs every frame. It advances fields over time, samples curves by `self.lifeRatio`,
  emits events, and decides when to die.

### 9.3 Evolve scopes (physics / timeFixed / timeVarying)

The engine bakes the evolve program into up to three optimizer variants (called *scopes*): **physics**,
**timeFixed**, and **timeVarying**. They are the *same* logic compiled under different update-rate and
time-discretization settings — **not** three programs. cornsyrup stores the evolve source **once** and
recompiles it into whichever scopes the layer needs on build. The `evolve physics { … }` hint just
records that this layer also needs the physics-scope copy; you edit one body and all scopes update.

---

## 10. Emission

Emission is driven from code, per frame, through the **generate → initPayload → kick** chain. Nothing
about spawning is implicit — a layer emits only what its script says to.

### 10.1 The accumulator

Spawn rate is fractional, so it's tracked with an **accumulator** kept in a persisted field
(`EventAccum` above). Each frame the code calls `generate(...)`, which:

- reads the accumulator (the leftover fractional count from last frame),
- adds this frame's contribution (rate × `dt`, or the event-stream/sampler's schedule),
- returns an `i32x3` whose lanes carry the **new carry**, the **running total**, and a **generator
  cache key**, and
- you write the updated accumulator back (`EventAccum = v6.xy`).

The **whole-number part** is how many particles to spawn this frame. There are three generators:

- **`generate(accum, …rate params…)`** — the general rate-based generator.
- **`EventStream.generate(accum, t0, t1, startTime, dt)`** — timeline-driven (from an EventStream
  sampler); emits according to baked trigger times.
- **`trigger(condition, timeFraction)`** — a one-shot: emits when a boolean condition is true
  (e.g. "emit a burst on death").

### 10.2 From count to particles

```
let gen : i32x3 = <generate/trigger>(...);       // this frame's spawn state (carry, total, key)
let key : i32   = Signal.initPayload(0, gen);    // park the count under the event
Signal.kick(key);                                 // dispatch the event
```

- **`initPayload(key, gen)`** parks the spawn count so the kick knows how many children to create,
  and returns the payload key. `gen` is the **whole `i32x3`** the generator returned, not just a
  count. The first argument is the **key** of the table this emission's appends fill and its kick
  reads: the event is the receiver, not the number. Any literal works, as long as two emissions of one
  program do not share it — they would share one table, and `build` refuses that. The baker numbers a
  layer's emissions `0, 1, 2, …` (one event kicked four times uses keys 0 to 3), so a program that
  emits once writes `0`.
- **`kick(key)`** fires the event. The engine looks up the event's subscribers (the child layers wired
  to it in the graph) and schedules `count` newborns in each, running their `init` scripts.

That's the entire spawn path: **the parent computes a count and kicks; the child layer's `init` runs
for each new particle.**

---

## 11. Events

Events are the wiring between layers. A layer **kicks** an event; the graph routes it to subscriber
layers, which spawn (or otherwise react). An event has **three separable parts**, one per file — this is
the key mental model:

| Part | Lives in | Answers |
|---|---|---|
| **schema** — the payload's fields, types, order | the layer's `event`/`root` declarations (§7) | *what data does this event carry?* |
| **routing** — source layer → target layers | the graph in `effect.cfx` (§4.2) | *who receives it?* |
| **behavior** — when it fires, what it carries | `code.cfx` (§8, §10, §12) | *when, and with which values?* |

An event by itself does nothing; it fires only when a layer's code calls `NAME.kick(…)`, and it spawns only
into whichever layers the graph wires to it. The three parts are edited independently and reunited on build.

### 11.1 Event slots and routing

The graph (`effect.cfx`, §4.2) records each event's source layer and its **target layers** as an edge
(`&L5 emits "Signal" -> [&L1, &L2, &L3]`). At runtime `kick(eventId)` dispatches purely on the event id →
the medium's event table → the connection-map subscribers resolved at bind time. A kicked event delivers
its payload to *each* target layer, which spawns `count` newborns and runs their `init`.

> **Any layer can kick.** Dispatch does **not** check the source layer's type (whether it "looks like"
> a spawner, has renderers, etc.). If a layer's bytecode contains a `kick()`, it fires. This is why
> render layers can still drive events.

### 11.2 `kick` — fan-out

`Object.kick(key)` fires the event named `Object` with the parked payload/count from `initPayload`.
Common event objects (the names are conventional — the leading `__e_` marks a compiler-minted event):

- **`Signal`, `__e_Signal N`** — user/spawn signals (e.g. "emit a trail this frame").
- **`__e_Child`** — the standard child-spawn event.
- **`__e_OnSpawn`, `__e_OnDeath`** — lifecycle events (fire when particles are born / die).

The event a layer *kicks* and the *root* of the child it spawns are two ends of the same contract: the
parent fills the kick event's payload, and the engine hands it to the child, which reads it in `init`. A
parent's kick payload is usually a **subset** of the child's root — the parent supplies what varies per
spawn (position, color), and the child's own spawner fills in the rest (count, lifetime).

### 11.3 `EventStream` sampler

An **EventStream** sampler is a baked timeline of trigger times. `EventStream.generate(...)` reads it
to decide emission per frame, and `EventStream.duration()` returns the timeline length — commonly used
to stop emitting when the timeline ends (the `self.lifeRatio = select(running & age ≤ duration, …)`
idiom).

### 11.4 `trigger` — conditional one-shots

`trigger(condition, timeFraction)` emits when `condition` is true for a particle. It shares the
same output shape as `generate`, so it plugs into the same `initPayload`/`kick` chain. Use it for
"burst on death", "emit once when X happens", etc.

### 11.5 Spatial layers

A **spatial layer** is a neighbour-query grid: it keeps a sparse spatial hash of every live particle's
world position so other layers can ask radius questions at script time. WC3 uses it for "find another
live target" effects (teleport runes, dispels, orbs).

- Declared in a layer's details: `spatial "…" local "__spatialLayer_N" flags F cell C { payload … }`.
- **`L.insert(at) { … }`** puts this particle into the grid at `at`, carrying the payloads the block
  names, each by the name the layer's `spatial` declaration gives it:

  ```
  __spatialLayer_0.insert(spatialKey2.xxx) {
      Position = localToWorldPosition;
  }
  ```

  A payload's index is its place in that declaration, so the names are the layer's own: another
  layer querying the same grid declares the payloads it reads, in its own order. `L.insert(at);`
  inserts with no payload. A `let` inside the block is evaluated where it stands.
- **`__spatialLayer_N.closestF3(centerXXX, radius, …)`** returns the closest neighbour's payload
  (e.g. its position) within a radius — or `+inf` if none. Its last argument is the payload's index
  in the querying layer's declaration.

The block is a spelling of the engine's calls, and `build` reads it as exactly these:

```
let k0 : i32 = __spatialLayer_0.allocatePayload();                        // a payload slot
let k1 : i32 = __spatialLayer_0.appendPayload(k0, localToWorldPosition, 0);  // the value, then the index
__spatialLayer_0.insert(k1, spatialKey2.xxx);                             // the last key, then where
```

which a program may also write by hand. A spatial layer's `appendPayload` takes the value before the
index, the other way round from an event's, and returns the key to append to next, as an event's
does. `decompile` writes every insert as a block, except one with a call made for its effect between
its calls (ice `145_SpatialLayers_Kernel` integrates its position there); `CFX_NO_PAYLOAD_SYNTAX=1`
writes every insert as its calls.

---

## 12. Payloads

A **payload** is the packet of data a spawn event carries from a **parent** particle to each **child**
it spawns — the child's initial position, color, orientation, size, etc. Its **shape is the `event`
declaration** for that event in the emitting layer (§7): an ordered list of typed elements. The parent fills the elements in
`evolve`; the engine delivers them; the child reads them in `init`. The element **index** is the only
handle both sides use — so the declared field order *is* the wire format (§7.3).

### 12.1 Producing a payload (parent side, in `evolve`)

The parent sends an event with its elements in an **`emit` block**, each element by the name its
`event` declaration gives it:

```
let gen : i32x3 = generate(accum, …);       // how many to spawn this frame (§10)
__e_Child.emit(gen) {
    Position = VectorLinear(prevPosition, position);   // interpolated over the frame
    Color = color;                                      // one value for every newborn
}
```

- **`E.emit(gen) { … }`** sends event `E` with the spawn state `gen` (the `i32x3` the frame's
  generator returned). `E.emit(gen);` sends it with no elements. An event whose name is not an
  identifier is sent quoted: `"__e_Signal 1".emit(gen) { … }`.
- **`Name = value;`** sends one value for every child born this frame.
- **`Name = Lerp(prev, cur);`** sends the element's value at the start and at the end of the frame,
  and the engine interpolates each newborn's between them. `Lerp` is `VectorLinear`, `VectorCubic`,
  `QuaternionNlerp` or `QuaternionSlerp`.
- **`kind K`** after an element (`Position = p kind Position;`) gives its kind (`Generic`,
  `Position`, `Orientation`, `EmittedCount`, §7.2). Without it, an interpolated element and an
  `EmittedCount` take the kind their declaration gives them, and a plain value takes `Generic`.
- **`key = N`** (`E.emit(gen, key = 2)`) names the cache the emission's table is kept in. Without it
  the key is the event's place among the layer's events, which is what the baker writes for all but
  a few emissions; a layer that sends one event several times in a frame gives each its own key.
- A **`let`** inside the block is evaluated where it stands, between the elements around it.
- Each element is built at the **type its event declares**: `build` refuses an element built from
  `f32` values for a payload declared `f32x3`, because the game sizes the element's storage by the
  built type and copies it by the declared one. It warns about a declared element an emission never
  sends (the child reads 0 for it).

The block is a spelling of the engine's calls, and `build` reads it as exactly these:

```
let key  : i32 = __e_Child.initPayload(0, gen);                    // the key, then the spawn state
let e0   : i32 = buildPayloadElement(gen, prevPosition, position, 1);
let key1 : i32 = __e_Child.appendPayload(key, 0, e0);              // element index 0 → a NEW key
let e1   : i32 = buildPayloadElement(gen, color, color, 0);
let key2 : i32 = __e_Child.appendPayload(key1, 1, e1);             // index 1, threading key1 → key2
__e_Child.kick(key2);                                               // fire with the LAST key
```

which a program may also write by hand:

- **`buildPayloadElement(gen, prev, cur, flags) -> i32`** computes one per-particle element and
  returns an opaque **handle** (an `i32`), not a typed value.
- **`appendPayload(key, index, element) -> i32`** records the element at the given **element index**
  and returns a **new key**. The index comes before the element, and the chain is **threaded**: each
  call's result feeds the next, and `kick` must receive the *last* key. Passing the original
  `initPayload` key to `kick` silently drops every element (`build` warns).
- **`initPayload(key, gen) -> i32`** opens the emission: its first argument is the cache key above,
  not the event's index, and it returns the first key.

#### The `flags` argument is a packed word, not a bitmask

`buildPayloadElement`'s trailing `int` is `(kind << 8) | lerp` — the engine's
`SPayloadElementView::PackSemantics`. The engine registers it as a **uniform** while every other
argument of the call is a stream, so it is always a literal. `stdlib/payload.cfx` names both fields:

```
import "stdlib/payload.cfx";

let flags : i32 = payloads.PackSemantics(payloads.Lerp.VectorCubic, payloads.EKind.Position);
let e0    : i32 = buildPayloadElement(gen, prev, cur, flags);
```

| field | values |
|---|---|
| `payloads.Lerp` (low byte) | `None` 0, `VectorLinear` 1, `VectorCubic` 2, `QuaternionNlerp` 3, `QuaternionSlerp` 4 |
| `payloads.EKind` (high byte) | `Generic` 0, `Position` 1, `Orientation` 2, `EmittedCount` 3 |

`VectorCubic` is the only mode that keeps `buildPayloadElementD`'s derivative arguments; the others
discard them. `EmittedCount` is the only kind the interpreter branches on — it disables lerping and
writes each child its own running index. It all constant-folds, so naming a value costs nothing.

**The decompiler names it.** Unlike `functions.cfx` (§13.6), the packed word *is* recoverable from
the bytecode: in an `emit` block it is the element's `Lerp(prev, cur)` and its `kind`, and where an
emission keeps its calls (below) `decompile` writes `let flags01 : i32 = payloads.PackSemantics(…);`
above each `buildPayloadElement` rather than a bare `768`. `CORNSYRUP_NO_PAYLOAD_FLAGS=1` emits the
literal.

> A **spatial layer**'s `appendPayload` is a different overload with the value and index the other
> way round (`__spatialLayer_0.appendPayload(key, pos, 0)`). The two are distinguished by receiver
> type; `split_polymorphic_calls` gives each its own call-table slot on build.
>
> `stdlib/spawn.cfx` (§13) wraps this chain as `spawn.emit` / `spawn.emit_1` / `_2` / `_3`, and
> `stdlib/events.cfx` builds elements with `events.emplace_*`. Both are **superseded** by the `emit`
> block, which names each element by its declaration, and stay for the bundles that call them.
>
> `decompile` writes every emission as a block, except one whose calls a block cannot say: a plain
> value sent with two different frames, an element built from another spawn state than the
> emission's. Those keep their calls. An element built once and appended to several emissions
> (massteleportto's runes send one colour with four events) is written in each block: `build`
> builds two equal elements once, as the baker does. `CFX_NO_PAYLOAD_SYNTAX=1` writes every
> emission as its calls.

### 12.2 Consuming a payload (child side, in `init`)

The child reads an element it was born with by its name in the layer's `root`:

```
let pos   : f32x3 = root.Position;         // the root's element Position
let color : f32x4 = root.Color;
let id    : i32   = root."Parent ID 01";   // a name that is not an identifier, quoted
```

`root.Name` reads with the read the element's declared type takes, at the element's place in the
layer's `root { … }`. That place is its place in the root the build merges too: the layer's own
elements come first, then whatever its parents send that it does not list. A layer whose root is
`root auto;` has no list to name from, so it reads by index (below); `build` says so if it is asked
to read by name.

The read it stands for can be written too, by index, with the `extractPayloadElement*` family:

```
let pos   : f32x3 = extractPayloadElementF3(1);   // read payload element #1 as a f32x3
let color : f32x4 = extractPayloadElementF4(4);   // element #4 as a f32x4
let n     : f32  = extractPayloadElementF1(0);   // element #0 as a float
```

- **`extractPayloadElementF1/F3/F4`** — read a float / f32x3 / f32x4 element.
- **`extractPayloadElementI1`** — read an int element.
- **`extractPayloadElementO`** — read an orientation/quaternion element.

`build` refuses a read at a type other than the element's (it would always read 0), and warns about
an index past the root, a read in an `evolve`, and a root element a parent does not send or sends at
another type (the baker's `_CheckPayloadCompatibility` warnings).

### 12.3 The full chain — one event across all three files

Here is a single event, `__e_Child`, shown from each file so the pieces line up. The parent layer `L0`
emits it; the child layer `L1` receives it.

**the emitting layer's declaration** — the schema (element indices in the left margin):

```
layer L0 {
    event __e_Child {        // idx │ what L0 sends
        Position = 7176;     //  0  │ per-child spawn position
        Color;               //  1  │ per-child color
    }
    root;
}
```

**`effect.cfx`** graph — the routing:

```
    &L0 emits "__e_Child" -> &L1;      // __e_Child from L0 spawns L1
```

**`code.cfx`** — the behavior (parent fills, child reads, by matching name):

```
layer L0 {
    evolve {
        let gen : i32x3 = generate(accum, …);            // how many to spawn, this frame
        __e_Child.emit(gen) {                            // fire → spawns L1 particles
            Position = VectorLinear(prevPosition, position);   // element 0 (Position)
            Color = color;                                      // element 1 (Color)
        }
    }
}
layer L1 {
    root {                   // what L1 is born with: what L0 sends
        Position = 7176;
        Color;
    }
    init {
        let pos : f32x3 = root.Position;                 // element 0 — Position (L0 sent it)
        let col : f32x4 = root.Color;                    // element 1 — Color
        n1__Position = pos;
        n1__Color    = col;
        self.invLife = rcp(rand(0.5, 0.8));              // the child's own lifetime (not inherited)
    }
}
```

`Position` and `Color` name the **same element index** on both sides — `0` and `1` in `L0`'s event
and in `L1`'s root — and that index is the whole contract: the block appends each element at its
place in the event, and `root.Name` reads it at its place in the root. The engine also reads the
`Position` element's
`Kind = 1` to place each newborn in `L0`'s frame (§7.2). Everything the parent doesn't send — here the
lifetime — the child fills from its own `init`.

---

## 13. Functions (`functions.cfx`)

A bundle may carry an **optional** `functions.cfx` defining reusable functions that any layer's
`init` or `evolve` can call. They are **always inlined at build time** — the compiled `.pkb` is
exactly what you would have got by writing the body out by hand, with no runtime cost and no new
engine surface. See `docs/design/CFX_FUNCTIONS_DESIGN.md` for the full specification.

```
// functions.cfx
import "stdlib/prelude.cfx";       // the library shipped next to the cornsyrup executable

fn ember_alpha(t: f32, hold: f32 = 0.6) -> f32 {
    let fade : f32 = math.remap(t, hold, 1.0);
    1.0 - easing.ease_in_quad(fade) // no `;` — the trailing expression is the return value
}
```

```
// code.cfx — any layer can now call it
n27__Color.w = ember_alpha(self.lifeRatio, hold = 0.4);
```

### 13.1 Syntax

Rust-shaped, with three additions to the statement language of §8:

- **`fn name(p: T, opt: T = default) -> R { … }`** — parameter types are mandatory; the return type
  is optional and **inferred from the trailing expression**. A trailing `;` makes the last line a
  statement, so the function returns nothing (Rust's rule — and a common first mistake).
  A parameter declared **`&T`** is taken by reference and writes back to the caller (§13.4).
- **`namespace N { … }`** — groups functions under a dotted path (`degrees.sin(78.0)`), the same
  shape as the engine's own `radians.*` / `fast.*` families. Nestable and reopenable across files.
  `::name(…)` forces global lookup, which is how a namespaced function wraps the intrinsic it
  shadows.

  Nesting can also be written **as a dotted path**, which means exactly the same thing:

  ```
  namespace coord.space.local { fn to_world(p: f32x3) -> f32x3 { … } }

  //  ≡

  namespace coord { namespace space { namespace local {
      fn to_world(p: f32x3) -> f32x3 { … }
  } } }
  ```

  Both define `coord.space.local.to_world`, both make `coord` and `coord.space` declared
  namespaces, and either may reopen what the other declared. Use whichever reads better: the dotted
  form for a leaf several levels down (where the nesting is pure indentation), the blocks when
  several things share an intermediate level. Whitespace around the dots is not allowed — `namespace
  a . b` is an error, since `namespace a` followed by something else is the likelier reading.

  A name is resolved by walking **outward**: from inside `coord.space.local`, a bare `helper(…)`
  tries `coord.space.local.helper`, then `coord.space.helper`, then `coord.helper`, then the global
  `helper`. An inner definition shadows an outer one of the same name.
- **`const NAME : T = expr;`** — a compile-time value; must fold to a literal.

A parameter may also be declared **`const &Renderer`** / **`const &Sampler`**, which takes a renderer
or sampler *handle* and resolves property reads through it at each call site — see §8.8.

**Functions overload.** Two `fn`s may share a name as long as a call can tell them apart: they must
differ in **how many arguments they take**, or in **which parameters are `&`**. Redefining the same
parameter shape names both sites as an error. Resolution is by the call's argument count and keywords,
so an overload may delegate to another of the same name (`integrate(p, v, g)` calling
`integrate(p, v)`) without that reading as recursion — `stdlib/physics.cfx` does exactly this. A call
that fits none of them lists the candidates.

A body is the ordinary statement language plus an optional `needs { … }` preamble declaring the
ambient externals it touches (`scene.dt`, `self.invLife`, a particle field). Those are merged into
the calling program's `needs` on build. Anything a body reads that is neither a parameter nor
declared is an error at load, naming the function.

> **A function declares even the derivable names.** The optional entries of §8.3 — `scene.dt`, the
> `Wc3.Attributes.…` constants (§8.9), a layer's events — are optional *in a layer program*, which
> has a layer around it to derive against. A module is loaded once, with no effect in hand, so a
> function body writes them out: `needs { "Wc3.Attributes.Scale" : f32; }`.

### 13.2 Calling — Python conventions

Positional first, then keyword; optionals can be named selectively and skipped:

```
f(1.0, 2.0);                    // optionals defaulted
f(1.0, 2.0, gain = 3.0);        // name just the one you want
f(1.0, 2.0, other = true);      // skip an earlier optional entirely
f(a = 1.0, b = 2.0);            // required params may be named too
```

A default may reference an earlier parameter (`fn g(a: f32, b: f32 = a * 2.0)`). There is no
`*args` / `**kwargs`.

### 13.3 Generics

```
fn approach<T: float>(cur: T, target: T, rate: f32) -> T { cur + (target - cur) * saturate(rate) }
```

Type parameters are monomorphized per call site — the caller's actual types are substituted and the
body re-checked. Bounds (`numeric`, `float`, `int`, `bool`, `scalar`, `vec`, combined with `+`) add
no capability; they exist to make errors clear.

### 13.4 Reference parameters (`&T`)

A parameter declared `&T` takes an **lvalue** — one of the caller's particle fields or externals —
and assigning it inside the body **writes back through** to that field:

```
fn physics(position: &f32x3, velocity: &f32x3, gravity: f32) {
    needs { "scene.dt" : f32; }
    velocity = velocity + #f32x3(0.0, 0.0, gravity * scene.dt * scene.dt * 0.5);
    position = position + velocity * scene.dt;
}
```

```
physics(Sim_Pos, Sim_Vel, 9.8);      // or physics(&Sim_Pos, &Sim_Vel, 9.8)
```

compiles to exactly the stores you would have written by hand:

```
let v : f32x3 = Sim_Vel + #f32x3(0, 0, ((9.8 * scene.dt) * scene.dt) * 0.5);
Sim_Vel = v;
Sim_Pos = Sim_Pos + v * scene.dt;
```

- A **read always yields the latest value written**, not a re-read of the field. Note the second
  line above uses `v`, not `Sim_Vel`. This is load-bearing, not cosmetic: the engine loads each
  external **once** per program, so a literal re-read after a store would return the *pre-store*
  value. References remove that footgun — they are safer than writing the stores by hand.
- Lane writes work: `p.y = 0.0;` on a `&f32x3` becomes a whole-field store that preserves the
  other lanes.
- A reference may be **passed on** to another function's reference parameter; writes chain
  correctly through any depth.
- The `&` at the call site is **optional** — the declaration already says which parameters write
  back. Writing it is allowed (and must then match the declaration).
- A reference may also be bound to a **`let` local**, not just a field — the motivating case is
  physics interleaved with a collision solver, where the integrated position is consumed by what
  follows rather than stored. Writing through a local **defines a new value**; it does not mutate
  what the local was initialised from. So after `let p = Position; let q = p; advance(q, Velocity);`,
  `q` carries the advanced value and `p` still reads the original — in SSA a write defines. No local
  definition survives inlining; the assembler only ever sees the flattened program.

Rejected, each with a specific message:

| | |
|---|---|
| a non-lvalue argument (`physics(Pos, Vel * 2.0, g)`) | there is nothing to write back to |
| two references to the same field (`physics(Pos, Pos, g)`) | writes through one would not be seen by the other |
| assigning a **by-value** parameter | suggests declaring it `&T` |

`stdlib/physics.cfx` builds on this. It is an overload set plus helpers:

| Function | What it does |
|---|---|
| `physics.integrate(position: &f32x3, velocity: f32x3)` | explicit Euler — advance position by velocity over one frame |
| `physics.integrate(position: &f32x3, velocity: &f32x3, gravity: f32 = 9.81)` | gravity, then integrate — the ballistic step |
| `physics.integrate(position, velocity, …)` *(full form)* | acceleration, wind, drag and mass in one velocity-Verlet step |
| `physics.integrate_in_field(position, velocity, field, …)` | the full form with a per-particle field velocity (a sampled turbulence) to drag toward |
| `physics.spin(rotation: f32, speed: f32) -> f32` | a billboard's rotation advanced by `speed` per second: `Rotation = physics.spin(Rotation, speed);` |
| `physics.bounce_floor(position: &f32x3, velocity: &f32x3, height = 0.0, restitution = 0.5)` | reflect off a horizontal plane, snapping rather than tunnelling |
| `physics.projection(position: &f32x3, velocity: &f32x3, shape: samplerShape_2C)` | project onto a shape sampler's surface, via `projectPCoords` / `sampleNormal` |
| `physics.collision(position: &f32x3, velocity: &f32x3, previous: f32x3, restitution = 0.5, enabled = true, filter = 0)` | bounce off the scene where the frame's motion from `previous` crosses it (`scene.intersect`), and move the rest of the frame from the contact point |
| `physics.collision(position, velocity, bounces: &i32, previous, …, bounces_before_death = 1, die_on_contact = false, …)` | the same, counting the bounces in a field that starts at 0 and killing the particle past `bounces_before_death`, or on contact |

Two conventions the module's own header spells out, because both are easy to get wrong: WC3 is
**Z-up**, so gravity acts on `z`; and every rate is **per second** — each function multiplies by
`scene.dt` itself, so never pre-scale.

> **`select`'s argument order is not PopcornFX's.** CFX writes `select(cond, whenTrue, whenFalse)` —
> condition **first**. PopcornFX's own `.pkfx` scripting writes `select(whenFalse, whenTrue, cond)` —
> condition **last**. Code ported from a `.pkfx` must have its `select` arguments reordered, or it
> silently computes the wrong branch.

### 13.5 Modules and the library

`import "path.cfx";` is searched in: the importing file's directory → the bundle root →
`CORNSYRUP_CFX_PATH` → `<exe_dir>/cfxlib/`. `import "…" as ns;` puts that module's items in a
namespace. A diamond import loads once; import cycles are harmless (definitions are
order-independent), but a **call** cycle is rejected — with no control flow, recursion cannot
terminate.

The shipped library lives at `<exe_dir>/cfxlib/stdlib/`. It is all plain CFX — copy a module into
your bundle and edit it.

| Module | Contents |
|---|---|
| `math.cfx` | `math.remap`, `math.inv_lerp`, `math.smoothstep`, `math.approach`, `math.safe_rcp`/`safe_div`, `math.PI`/`TAU`/`DEG2RAD`, and the `degrees.*` trig namespace |
| `vec.cfx` | `vec.UP`/`FORWARD`/`RIGHT` (+z, +y, +x: the game's Z-up frame), `vec.normalize`, `vec.length`, `vec.safe_normalize`, `vec.safe_normalize_template`, `vec.dist`, `vec.dir_to`, `vec.project`, `vec.reflect`, `vec.with_x/y/z`, `vec.scale_xy` |
| `easing.cfx` | `easing.ease_in/out_quad`, `easing.ease_in/out_cubic`, `easing.ease_sine`, `easing.pulse`, `easing.fade_in_out`, `easing.decay` |
| `color.cfx` | `color.with_alpha`, `color.fade`, `color.mix`, `color.gamma`, `color.grading`, `color.adjust_hsv`, `color.fade_on_stop` |
| `random.cfx` | `random.rand_signed`, `random.rand_around`, `random.rand_box`, `random.rand_dir`, `random.rand_dir_xy` (horizontal), `random.jitter` |
| `life.cfx` | `life.set_lifetime`, `life.kill_when`, `life.age_ratio`, `life.ratio_since_stop`, `life.select_texture_id_on_age` (§8.8) |
| `spawn.cfx` | `spawn.emit` / `emit_1` / `emit_2` / `emit_3` — the `initPayload`→`appendPayload`→`kick` chain (§12.1) |
| `events.cfx` | `events.trigger_on_death` (PopcornFX's `SimpleOnDeath`: the spawn state of the tick a particle dies), `events.emplace_payload/position/element` (one `EventPayloadAppend` each) |
| `payload.cfx` | `payloads.PackSemantics` and the `Lerp` / `EKind` names (§12.1) |
| `physics.cfx` | the motion integrators above (§13.4) |
| `xform.cfx` | the `xform.*` mask words every `xform_*_masked` call ends with — filter bits, space enums, and the nine masks the corpus actually contains |
| `space.cfx` | `coord_space.local_to_world_position`, `…_direction`, `world_to_local_*`, `world_prev_to_world_position`, `world_base_position` — **one function per mask**, built on `xform.cfx` — and `coord_space.rotation_about_z`, the spin quaternion |
| `templates.cfx` | the `template` library (§14.9) |
| `popcorn.cfx` | `popcorn.EventMultiplier`, `popcorn.InfiniteLife` and the other layer templates PopcornFX's own templates bake to (§14.9), the ones `decompile` writes instances of |
| `wc3/part2.cfx` | helpers lifted from the Warcraft III emitters: `wc3.coneAngleVelocity`, `wc3.physics`, `wc3.squirt` and the `wc3.SquirtEmitter` layer template |
| `prelude.cfx` | one import for the common four: `math`, `vec`, `easing`, `life` |

Every module hides its functions and constants behind a namespace of its own, mostly named after the
file — `math.remap`, `vec.dir_to`, `life.kill_when`. The ones that are not are `degrees` (in
`math.cfx`), which mirrors the engine's `radians.*` intrinsic family, `payloads` (`payload.cfx`),
`coord_space` (`space.cfx`) and `wc3` (`wc3/part2.cfx`). No function or constant reaches global
scope, so importing the library can never collide with a bundle's own functions. The exception is
`templates.cfx`, whose templates are global, under the names §14.9 lists.

> `xform.cfx` and `space.cfx` are not conveniences. All eight `xform_*_masked` script names bind to a
> **single** engine function, so the mask word is the only thing that distinguishes them — which is
> why `space.cfx` defines one function per mask, and only for masks the baker actually writes. A
> function carrying a mask no blob contains describes nothing, and the reconstruction recognizer
> (§13.6) will match real regions against it and then discard them.

What the library stands for in PopcornFX, checked by baking the node and the library call side by side
(`docs/engine/frame-and-library-nodes.md`); "same" means the same program:

| PopcornFX | CFX | |
|---|---|---|
| `Transform` node (InputSpace, OutputSpace, Rotate) | `coord_space.*` | same masks: 19, 18, 67, 66, 107, and 17 for the origin |
| `Physics` template (Dynamics.pkfx) | `physics.integrate`, all three overloads | same arithmetic; the template also writes the physics-rate program (`evolve physics`) |
| `Projection` template, `Localspace` on | `physics.projection` | same |
| `SimpleOnDeath` event (Events.pkfx) | `events.trigger_on_death()` | same |
| `EventPayloadAppend` | `events.emplace_*` | same |
| `SetLife` | `life.set_lifetime` | same: a Life of 0 dies on its first update, `inf` never ages |
| `safe_normalize(v, fb, eps)` | `vec.safe_normalize` | same, `eps` on the length, 1e-12 by default |
| `vrand()` | `random.rand_dir()` | same |
| `smoothstep(a, b, x)` | `math.smoothstep(a, b, x)` | same |
| `linearstep(a, b, x)` | `math.remap(x, a, b)` | same |
| `remap(x, a, b)` | `lerp(a, b, x)` | **not** `math.remap`: PopcornFX's maps [0, 1] onto [a, b] |
| `remap(x, a, b, c, d)` | `math.remap_range(x, a, b, c, d, clamped = false)` | PopcornFX's does not clamp |
| `fracSign(x)` / `frac(x)` | `frac(x)` / `_frac_unsigned(x)` | see §15.3 |

These stand for PopcornFX templates by the shape the templates bake to, verified against the game
corpus (every reconstructed call rebuilds to the region it replaced) rather than baked side by side:

| PopcornFX | CFX |
|---|---|
| `InfiniteLife`, `FadeOnStop` (the stop timer) | `life.ratio_since_stop(timer, rate)` |
| `FadeOnStop` (the colour) | `color.fade_on_stop(c, time_since_stop)` |
| `Color` | `color.adjust_hsv(rgba, shift, variation)` |
| `Legacy_Rotation`, defaults | `physics.spin(rotation, speed)` |
| `Physics` with a vector field | `physics.integrate_in_field` |
| `Collision`, `CollideWith` Scene, `Absorbsive` friction | `physics.collision`, the bounce count a field (`bounces`) where it kills; its `OnCollide` event and `HasCollided` are not outputs |
| Core "safe normalize" | `vec.safe_normalize_template(v, fallback)` |
| `normalize(v)`, `length(v)` | `vec.normalize`, `vec.length` |
| a constant-rate spin about Z | `coord_space.rotation_about_z(time, degrees_per_second)` |
| `Transform` masks 11, 23, 65 | `coord_space.world_prev_to_world_position`, `…local_to_world_position_scaled`, `…world_to_local_position_xtrans_only` |

### 13.6 Functions are one-way

**The decompiler never emits a function definition.** Inlining is lossy at the source level by
construction (the bytecode has no call frames — and never did; the baker inlines too), so:

> Two things do come back as library calls, and neither contradicts this: `reconstruct` puts back
> calls it can *prove* recompile to the region they replace, and `payload_flags` (§12.1) names a
> constant that only ever had one spelling. Both emit into `functions.cfx`'s import list, which is
> why `decompile` writes that file when it does not already exist.
>
> The list is exactly the modules those passes can draw on — `stdlib/physics.cfx`,
> `stdlib/life.cfx`, `stdlib/space.cfx`, `stdlib/color.cfx`, `stdlib/vec.cfx`, `stdlib/spawn.cfx`,
> the layer templates of `stdlib/templates.cfx` and `stdlib/popcorn.cfx` (§14.7), and
> `stdlib/payload.cfx` — and it is
> deliberately short: every function loaded there is one more that could be emitted into a bundle, so
> it holds only the shapes whose reconstruction is verified against the corpus. A bundle must import
> exactly what was matched against, or a reconstructed call would not resolve on rebuild. With no
> `cfxlib` on the search path, reconstruction simply switches itself off.

```
functions.cfx + code.cfx  ──build──▶  pkb           ✔ correct, inlined
pkb                       ──decompile──▶  code.cfx   ✘ comes back fully inlined
```

Keep the `.cfxb` directory as your source of truth — the same discipline the format already needs
for comments and identifier names. `decompile` will not overwrite an existing `functions.cfx`.

---

## 14. Templates

A `layer`, `renderer` or `sampler` you write over and over — the root emitter, the soft billboard,
the shape a dozen effects spawn from — can be declared once as a **template** and pulled in with
`extends`:

```
layer RootLayer extends RootLayerTemplate {
    event Signal;
    using {
        "_ev_Signal"      = Signal;
        "_sd_eventStream" = sd0;
    }
}
```

`build` merges the template's declarations into the layer and compiles the result. The `.pkb` is
**exactly** what writing the layer out longhand would have produced.

### 14.1 What a template is

A structural macro over a declaration — the same idea as a function, one level up: a function
parameterises an *expression*, a template parameterises a *declaration*. Expansion is a text merge
that runs before every other parser, so nothing downstream (the graph, the event and field readers,
the renderer and sampler parsers, the compiler) ever learns that templates exist.

Consequences worth keeping in mind: templates cost nothing at runtime, cannot change what an effect
does, and — like functions — are **one-way** (§14.7).

Templates live in the authored library, in `functions.cfx` and whatever it imports, beside `fn` and
`const`. That is what lets `<exe>/cfxlib/stdlib/templates.cfx` carry the root emitter once for every
bundle on the machine.

### 14.2 Declaring one

```
template layer RootLayerTemplate {
    takes {
        "_ev_Signal" : particleEvent;
        "_sd_eventStream" : samplerEventStreamC;
    }
    properties {
        Events = [];
        NeedsEvolveOnDeath;
        sampler "EventStream" : EventStream = &_sd_eventStream;
    }
    root;
    init   { needs { "self.invLife" : f32; } self.invLife = 0.0; }
    evolve {
        needs { "_ev_Signal" : particleEvent; "EventStream" : samplerEventStreamC; }
        let events : i32x3 = EventStream.generate(EventAccum, prevAge, age, 0.0, scene.dt);
        _ev_Signal.kick(_ev_Signal.initPayload(0, events));
    }
}
```

```ebnf
template_item = "template" kind ident [ ":" type ] [ extends ] "{" [ takes ] { member } "}" ;
kind          = "layer" | "renderer" | "sampler" ;
takes         = "takes" "{" { param ":" type [ "=" arg ] ";" } "}" ;
param         = string_lit | ident ;

extends       = "extends" ident { "," ident } ;
using         = "using" "{" { param "=" arg ";" } "}" ;
arg           = ident | string_lit | expr ;
```

A `template layer`'s members are the ordinary layer sub-blocks (`properties`, `event`/`root`,
`init`, `evolve`, `bind`); a `template renderer` / `template sampler`'s members are its property
lines. `: Type` fixes the renderer geometry or sampler kind, and the child inherits it.

### 14.3 Parameters

A `takes` entry is a hole in a declaration, and its **type** decides how it is filled:

| Parameter type | Bound to | Substitution |
|---|---|---|
| handle types — `particleEvent`, `sampler*C`, `SpatialLayerType` | a **name**: `Signal`, `sd0` | every occurrence of the parameter token is **renamed** |
| value types — `f32`, `i32x2`, `bool`, `texture`, … | an **expression**: `10.0`, `inf`, `(8, 8)` | every reference becomes that expression, then const-folds |

The split exists because CFX addresses events, samplers and spatial layers **by name** — in `needs`,
as a method receiver, and in `properties` — so binding one is a rename, not a value substitution.

**A handle binding is the bare name, never `&name`.** The `&` belongs to the reference site: the
template writes `= &_sd_eventStream;`, the child writes `"_sd_eventStream" = sd0;`, and the rename
produces `= &sd0;` — the exact text a hand-written layer has.

Substitution is **token-aware**. A parameter named `rate` renames a bare `rate` and a quoted
`"rate"` key, but never `rateScale` and never a `"…rate…"` fragment inside a path. So a parameter
can be named anything; the `_t_` / `_ev_` / `_sd_` prefixes in `stdlib/templates.cfx` are a marker
for the reader, not a requirement.

**Optional parameters** carry a default and may be omitted from `using`:

```
takes { "_t_Duration" : f32 = inf; }
```

`inf` is worth the example: `self.invLife = rcp(_t_Duration)` const-folds to `self.invLife = 0.0`,
so an optional parameter left at its default costs nothing over hand-writing the result.

Every required parameter must be bound, and `using` may not name a parameter the template does not
take. Both are errors, not silent no-ops. With more than one template — `extends A, B`, or a
template that extends another — the one `using` block binds all their parameters: each entry is
checked against the template that takes it, and one that no template takes is the error, as is one
that a template on the way already binds itself (§14.6).

### 14.4 How the merge works

**The child adds to the template; a declaration made on both sides is an error.**

| Member | Merge | Conflict |
|---|---|---|
| `properties { … }` | union of the entries | same key on both sides → error, but for the same `attrib` line (below) |
| `event NAME` / `root` | union | duplicate event name, or two `root`s → error |
| `bind <rend> { … }` | union, keyed by renderer handle | same renderer bound twice → error |
| `fields` | union, template's first | a field typed two ways → error |
| `init` / `evolve` | **concatenated**, template first | — (`needs` unions; a type clash is an error) |
| renderer / sampler property lines | union, template's first | same property on both sides → error |

Error-on-conflict rather than child-wins is deliberate. An override that silently drops the
template's value is invisible at the call site, and these declarations — a payload's field order, a
`bind` slot — are exactly where a silent drop turns into a long afternoon.

`init` and `evolve` are the one member where both sides legitimately contribute, so they append:
**template statements first, then the child's**, with the `needs` blocks merged into one. That is
well defined precisely because CFX has no control flow (§8): a program is a statement sequence, so
"template then child" is a total order with nothing to reconcile. A child that needs to *replace* a
template's program should not extend that template — splitting the template in two is clearer than
an override keyword.

`evolve physics` is a property of the merged result: if either side asks for the physics scope, the
merged layer gets it.

What is **not** inherited is the declaration's identity. `layer RootLayer extends …` is still named
`RootLayer`, and the graph, the events and the field flags all key off that name.

**A template may declare its own `event`s**, and that is often the better shape: events union, so
the merged layer carries them, the graph wires them by name and the `.pkb` has them — no
`particleEvent` parameter, no `using` line, nothing for the child to get wrong. The price is that
the **name becomes part of the template's contract**. A child that declares the same name is the
ordinary duplicate error, loud and easy. A child that declares a *different* one is not an error at
all: the merged layer ends up with both events, the graph is still wired to the child's, and nothing
kicks it — the build succeeds and the effect is dead. So declare the event when the template is
written first, and parameterise it when the template has to slot into layers that already exist.

**A layer template that declares `root` can only be extended by a layer that declares none.** `root`
is the one member with no merge to fall back on — two of them is an error outright — and a `root`
payload is what *this* layer's newborns receive from whoever spawned them, which has nothing to do
with how the layer emits. The shipped layer templates do declare `root;`, because the corpus layers
they were lifted from carry one and a layer built without it is a different layer; the consequence
is that a layer needing its own payload writes the emitter out longhand instead of extending one.
Take the same care with `properties`: a template should declare the entries it actually needs and
leave the layer's own `Renderers`, samplers and attributes alone, since those merge alongside it
perfectly well.

**A template declares the game attributes it reads.** A program reads an attribute only through
the layer's binding of it (§8.1), so a template whose code reads one writes the binding too:

```
template layer ScaledEmitter extends EventMultiplier {
    takes { "_t_Rate" : f32; }
    using { "_t_EmissionRate" = Wc3.Attributes.EmissionRateMultiplier * _t_Rate; }
    properties {
        attrib "__a_Game.EmissionRateMultiplier";   // what the `using` above reads
    }
}

layer Sparks extends ScaledEmitter { using { "_t_Rate" = 40.0; } }
```

That is all a layer extending it needs. The attribute is a standard one, so `effect.cfx` does not
have to declare it either: the build does, when no declaration is there (§4.1). A template that
reads an effect-local attribute (`"Wind"`, `"MySpell.Intensity"`) binds it the same way, but the
effect still has to declare that one, since nothing else knows its type or default. The library's
`Scaled` emitters (§14.9) are templates of this kind, and `decompile` writes the game's emitters
whose rate follows the multiplier as instances of them (§14.7).

An `attrib` line is the one entry two sides may both write. It binds an attribute and carries no
value of its own, so the same line from the template and the layer, or from two templates the layer
extends, is one binding. That is how two templates that both read `EmissionRateMultiplier` combine,
and how a layer that already binds all seven `Game.*` attributes extends one. Two *different* lines
for one attribute, such as a long form beside a short one, are still the duplicate error. An
`attrib` entry is keyed by its attribute however it is written.

### 14.5 Member order, and where it bites

The merged members keep their order: the template's, then the child's. For a **sampler** that order
survives into the `.pkb` — reordering a sampler's fields by hand changes the bytes too — so a
sampler template must carry the **leading** fields and take whatever varies as a parameter (the
shipped `SimpleCylinder` is this, with `InnerRadius` as one more optional parameter):

```
template sampler Cylinder : Shape {
    takes { "_t_Position" : i32x2; "_t_Radius" : f32; }
    WorkspacePosition = _t_Position;      // has to lead, so it has to be here
    SampleDimensionality = 3;
    ShapeType = Cylinder;
    Radius = _t_Radius;
}

sampler sd2 extends Cylinder {
    using { "_t_Position" = (-1650, -220); "_t_Radius" = 3; }
    InnerRadius = 1.776;                  // appended after the template's fields
}
```

**Renderers are immune**: `build` reconstructs their full property list in the baker's own order
(§6), so a renderer template can put its properties in whatever order reads best.

**A layer's `attrib` lines** come out in the merged order too, the template's first, and that order
reaches the `.pkb`. It changes the bytes and nothing else: the engine finds a layer's attributes by
name.

### 14.6 Composition

A template may `extends` another, and a declaration may extend several, merged left to right under
the same conflict rule. Bases are flattened depth-first, so a base's declarations sit ahead of the
derived template's — the same position the child sees. A cycle is rejected with the path.

A template that extends another decides what becomes of each of its base's parameters:

```
template layer Base    { takes { "_t_Rate" : f32; } … }
template layer Fast    extends Base { using { "_t_Rate" = 8.0; } }            // binds it
template layer Scaled  extends Base { takes { "_t_Life" : f32; }
                                      using { "_t_Rate" = 2.0 * _t_Life; } } // binds it to its own
template layer Tunable extends Base { takes { "_t_Rate" : f32 = 2.0; } }     // passes it on
```

- Its own `using` **binds** the base's parameter. The value may use the derived template's own
  parameters, as `Scaled` does. Such a `using` may bind only its bases' parameters.
- Re-declaring the parameter in its `takes` **passes it on**: the base gets what the layer binds,
  or the derived template's default (`layer L0 extends Tunable { }` gets 2.0).
- A parameter it does neither with stays open, and the layer binds it directly.

A parameter is bound once. A layer that binds `_t_Rate` while extending `Fast` is an error, not an
override: `Fast` has settled it. To offer a value a layer may change, pass the parameter on with that
value as the default, as `Tunable` does.

Templates namespace like functions. A declaration in `code.cfx` is at global scope, so a namespaced
template is named by its full path:

```
namespace emitters { template layer Root { … } }

layer L0 extends emitters.Root { … }
```

### 14.7 Templates are one-way

The same contract as functions (§13.6): `decompile` never infers a `template` from an effect, and
never one from your templates, because the merge is lossy at the source level by construction. What
it may write is an **instance of a library template**: a layer that one of the layer templates of
`stdlib/templates.cfx` or `stdlib/popcorn.cfx` (§14.9) describes comes out as

```
layer L3 extends popcorn.EventMultiplier {
    using {
        "_t_Count" = scene.dt * 20.0;
    }
}
```

and only where that instance expands back to the very layer it read, so the rebuild is the same
program: 8,482 of the game corpus's 21,979 layers. `CFX_NO_TEMPLATES`
writes every layer longhand.

A layer whose rate follows the unit's emission rate multiplier, as most of the game's emitters do,
comes out as an instance of one of the `Scaled` emitters (§14.9). The template binds the attribute
itself, so the layer keeps only the rate and its other attributes:

```
layer L7 extends popcorn.ScaledEmitter_23a77ec7 {
    using {
        "_t_Rate" = 71.428566;
        "_t_Life" = 0.14;
    }
    properties {
        attrib "__a_Game.Global.Spawning";
        attrib "__a_Game.SpeedMultiplier";
        …
    }
}
```

The build writes the template's `attrib` line ahead of the layer's own, the one way an instance may
differ from the layer it read: the engine finds a layer's attributes by name, never by their place
in the list. Keep the `.cfxb` directory as your source of truth; `decompile` will not
overwrite an existing `functions.cfx`.

### 14.8 Errors

| Condition | Message shape |
|---|---|
| Unknown template | `no template 'RootLayerTemplat' (did you mean 'RootLayerTemplate'?)` |
| Missing binding | ``L0: template RootLayerTemplate takes '_ev_Signal', which `using` does not bind`` |
| Unknown binding | `L0: RootLayerTemplate has no parameter '_ev_Signl' (takes: _ev_Signal, _sd_eventStream)` |
| Bound twice | ``L0: '_t_Rate' is bound by Fast's `using`, and again by L0 — …`` |
| A template's `using` binds no base parameter | ``L0: Bad's `using` binds '_t_Nope', which none of its bases takes (takes: _t_Rate)`` |
| Conflict | `L0: 'NeedsEvolveOnDeath' is declared by both RootLayerTemplate and L0` |
| Unbound event | `L0: '_ev_Signal' is bound to event 'Ghost', which this layer does not declare (declares: Signal)` |
| `needs` type clash | `L0: 'X' is needed as f32 and as i32x2 in the merged evolve` |
| `fields` type clash | `L0: field 'X' is declared as f32 and as i32x2 in the merged layer` |
| `names` in a template | ``L0: Burst has a `names` block; a template writes the names the `.pkb` stores, …`` |
| Wrong binding form | `L0: '_sd_eventStream' is a handle — bind it to a name (sd0), not a reference (&sd0)` |
| Cycle | `template cycle: A → B → A` |
| Kind mismatch | `layer L0 cannot extend 'GlowBillboard' (a renderer template)` |

### 14.9 The shipped library

`import "stdlib/templates.cfx";` brings in prototypes lifted from real decompiled bundles. Each builds
what the baker writes for the same node setup, down to leaving a default unwritten:

| Template | Kind | What it is |
|---|---|---|
| `RootLayerTemplate` | layer | the `EventStream`-driven root emitter — layer 0 of essentially every effect. Unlike the §14.2 example it declares its own `Signal` event and takes only `_sd_eventStream` |
| `EventMultiplier` | layer | a rate-driven emitter: N events per second for a duration |
| `TerminationTemplate` | layer | the "keep the effect alive until it stops, then die" tail layer |
| `TexturedBillboard` | renderer | the plain textured quad; a draw order other than 0 is the child's `DrawOrder = N;` |
| `SoftBillboard` | renderer | fades against scene geometry instead of cutting into it; screen-aligned unless `_t_Mode` says otherwise (an axis mode needs `Axis0` bound) |
| `AtlasBillboard` | renderer | flipbook, `(columns, rows)` subdivision; the frame is the `TextureID` input |
| `SingleShot` | sampler | the one-entry `EventStream` timeline `RootLayerTemplate` reads |
| `SimpleCylinder` | sampler | a solid cylinder spawn volume (`_t_Position`, `_t_Radius`); a tube adds `InnerRadius = r;` |

`import "stdlib/popcorn.cfx";` brings in the layers PopcornFX's own templates bake to, each written
as `decompile` writes the baked layer (its hashed field names included) and taking the values that
vary from effect to effect:

| Template | What it is |
|---|---|
| `popcorn.EventMultiplier` | PopcornFX's `EventMultiplier`: kicks `__e_Child` `_t_Count` times a frame (`scene.dt * rate`), life `_t_Life` (`inf` by default) |
| `popcorn.Emitter_09e45c63`, `popcorn.Emitter_23a77ec7` | the same program from the game's own template library, under its field names |
| `popcorn.ScaledEventMultiplier`, `popcorn.ScaledEmitter_09e45c63`, `popcorn.ScaledEmitter_23a77ec7` | each of the three at a rate the unit's emission rate multiplier scales: `_t_Rate` events a second at a multiplier of 1 (`_t_Count = scene.dt * (Wc3.Attributes.EmissionRateMultiplier * _t_Rate)`), life `_t_Life`. Each binds `Game.EmissionRateMultiplier` itself (§14.4) |
| `popcorn.InfiniteLife` | PopcornFX's `InfiniteLife` on a root layer of its own: lives until the effect stops, then one more second |
| `popcorn.StopTimer_4f9baf59` | the same with no delay, from the game's own library: dies on the first stopped frame |

---

## 15. Reference tables

### 15.1 Statements

| Syntax | Meaning |
|---|---|
| `let NAME : T = EXPR;` | bind a temporary |
| `Target = EXPR;` | store to a field/external |
| `Target.<comps> = EXPR;` | swizzle store — write only the named lanes of a vector external |
| `EXPR;` | void (side-effecting) call |

### 15.2 Operators

`+` `-` `*` `/` `%` · `<<` `>>` `&` `|` `^` · `<` `<=` `>` `>=` `==` `!=` · prefix `-x` / `!x` (or
`neg(x)` / `lnot(x)`) · `select(cond, a, b)`. Prefix `-`/`!` apply to any operand and bind tighter than
the binary operators but looser than postfixes, so `-a.x` is `neg(a.x)` and `-a * b` is `(-a) * b`.

### 15.3 Math intrinsics — full list

Math intrinsics operate per-lane on scalars or vectors (a `f32x3` argument gives a `f32x3` result,
etc.), unless noted. Arity picks the intrinsic (1/2/3 arguments).

**Unary** — `f(x)`:

| Name | Meaning | Name | Meaning |
|---|---|---|---|
| `rcp(x)` | `1 / x` | `abs(x)` | absolute value |
| `sign(x)` | −1 / 0 / +1 | `frac(x)` | `x − trunc(x)` (sign-preserving: PopcornFX's `fracSign`)¹ |
| `saturate(x)` | clamp to `[0, 1]` | `ceil(x)` / `floor(x)` | round up / down |
| `exp(x)` / `exp2(x)` | `e^x` / `2^x` | `log(x)` / `log2(x)` | natural / base-2 log |
| `radians.sin(x)` | sine (radians) | `radians.cos(x)` | cosine |
| `radians.tan(x)` | tangent | `radians.sincos(x)` | `→ f32x2` (sin, cos) |
| `radians.asin/acos/atan(x)` | inverse trig | `all(v)` / `any(v)` | `→ bool` reduction |
| `isfinite(x)` / `isinf(x)` | `→ bool` | `neg(x)` / `lnot(x)` | negate / not (bitwise on an int) |

¹ The name is not PopcornFX's. A PopcornFX script's `frac(x)` is `x − floor(x)`, always in `[0, 1)`
(`frac(-2.345)` is `0.655`); its `fracSign(x)` is the sign-preserving one CFX calls `frac`
(`-0.345`). Both are engine MathFunc1 intrinsics, 22 and 23; `decompile` writes the first as
`_frac_unsigned(x)`. Code ported from a `.pkfx` turns `frac` into `_frac_unsigned` and `fracSign`
into `frac`.

Fast (lower-precision) variants: `fast.sqrt`, `fast.rsqrt`, `fast.cbrt`, `fast.length`,
`fast.normalize`, `fast.exp`, `fast.exp2`, `fast.log`, `fast.log2`, `fast.rcp`, and
`fast.sin/cos/tan/…` mirrors.

**Binary** — `f(a, b)`:

| Name | Meaning |
|---|---|
| `min(a, b)` / `max(a, b)` | per-lane minimum / maximum |
| `dot(a, b)` | dot product `→ float` |
| `cross(a, b)` | cross product (`f32x3`) |
| `step(edge, x)` | `x < edge ? 0 : 1` |
| `discretize(x, step)` | snap `x` to a multiple of `step` |
| `radians.atan2(y, x)` | two-argument arctangent |

**Ternary** — `f(a, b, c)`:

| Name | Meaning |
|---|---|
| `lerp(a, b, t)` | linear interpolation `a + (b − a)·t` |
| `clamp(x, lo, hi)` | clamp `x` to `[lo, hi]` |
| `within(x, lo, hi)` | boolean range test (`lo ≤ x < hi`) |

### 15.4 Full engine API

Notation: **`name(arg: Type, …) -> Result`**. Object methods are written `handle.name(…)` where
`handle` is a sampler (`__sampler_N`), an event (`Signal`, `__e_Child`, …), or a spatial layer
(`__spatialLayer_N`). **Context arguments** (`ParticleContextS`/`I`/`N`, `RandContext`, `SceneContext`)
are **auto-supplied** by the compiler and never written in a natural call — they're listed under
*ctx* for reference. Some functions are **result-polymorphic**: `sample`, `rand`, and the
`extractPayloadElement*` family take their result type from the `let : T` annotation at the call site.

#### Effect / scene / view queries

| Signature | ctx | Description |
|---|---|---|
| `effect.age() -> f32` | pCtxI | seconds since the effect started |
| `effect.isRunning() -> bool` | pCtxI | is the effect still emitting |
| `effect.position() -> f32x3` | pCtxI | the effect's world position |
| `view.distance(worldPos: f32x3) -> f32` | SceneCtx | camera → point distance |
| `view.resolution(x: i32) -> i32x2` | SceneCtx | viewport resolution |
| `view.position(x: i32) -> f32x3` | SceneCtx | the camera's world position |
| `view.direction(x: i32) -> f32x3` | SceneCtx | the direction the camera is looking |
| `view.axisSide(x: i32) -> f32x3` | SceneCtx | the camera's side (right) axis |
| `view.axisUp(x: i32) -> f32x3` | SceneCtx | the camera's up axis |
| `view.axisForward(x: i32) -> f32x3` | SceneCtx | the camera's forward axis |
| `view.axisLeft / axisRight / axisDown / axisBackward(x: i32) -> f32x3` | SceneCtx | the other four named axes |
| `view.axisVertical / axisDepth(x: i32) -> f32x3` | SceneCtx | the same frame, under its other spelling |
| `view.velocity(x: i32) -> f32x3` | SceneCtx | how fast the camera is moving |
| `view.orientation(x: i32) -> orientation` | SceneCtx | the camera's orientation as a quaternion |
| `view.fov / fovHorizontal / fovVertical(x: i32) -> f32` | SceneCtx | field of view |
| `view.aspect(x: i32) -> f32` | SceneCtx | viewport aspect ratio |
| `view.lodBias(x: i32) -> f32` | SceneCtx | the camera's LOD bias |
| `effect.axisForward() -> f32x3` | pCtxI | the effect's own forward axis |
| `effect.axisUp / axisLeft / axisRight / axisDown / axisBackward() -> f32x3` | pCtxI | the rest of the effect's frame |
| `effect.axisSide / axisVertical / axisDepth() -> f32x3` | pCtxI | the same frame, under its other spelling |
| `effect.orientation() -> orientation` | pCtxI | the effect's orientation |
| `effect.scale() -> f32x3` | pCtxI | the effect's scale |
| `effect.velocity() -> f32x3` | pCtxI | how fast the effect is moving |
| `effect.visible() -> bool` | pCtxI | is the effect visible |
| `effect.lodBias() -> f32` | pCtxI | the effect's LOD bias |
| `sim.lod() -> f32` | pCtxS | the simulation level-of-detail metric — a remap of √distance over √5…√200, `0` with no view |
| `scene.intersect(a, b, c, d, e) -> f32x4` | SceneCtx | scene/geometry intersection query |
| `scene.orientation_f_norm(normal: f32x3) -> orientation` | — | orientation aligned to a normal |
| `scene.orientation_u_norm(normal: f32x3) -> orientation` | — | the same, aligned about the up axis |
| `scene.orientation_fu_norm(forward, up) -> orientation` | — | orientation from a forward and an up vector |
| `orientation_mult(a: orientation, b: orientation) -> orientation` | — | compose two orientations |
| `noise(v: f32x3) -> f32` | — | scalar gradient noise |
| `fast.noise(v: f32x3) -> f32` | — | the low-precision variant (the `fast.*` family, §15.3) |

The `view.*` family takes an `i32` argument that every corpus site passes as `0`; it selects **which
camera** on a machine with more than one. The index is **mandatory** — only `view.distance` and
`view.closest` have index-free forms. The `effect.*` family takes no argument at all.

The names above are the engine's own: `RegisterForLink_View` binds 27 symbols and
`RegisterForLink_Effect` 19, and the shipped corpus uses only a fraction of them. The rest are listed
here because they are callable, not because anything ships with them. A handful of each family is
still absent — `view.count`, `view.project`/`unproject`/`unprojectedAxis`/`closest`, and
`effect.lodBiasMin`/`lodBiasMax` — because their argument marshalling is not implied by any signature
the corpus carries, and a wrong one mis-binds the call instead of failing the build. Ask if you need
one. A name outside both sets is refused where it is written, with the family listed.

**Game-specific script imports.** War3 effects may call host-provided predicates, prefixed
`_pksi_War3.` (`_pksi` = *PopcornFX script import*). The one seen in the corpus is
`_pksi_War3.HasTeleported_SI() -> bool` (ctx: pCtxI) — a game-driven flag. These are resolved by the
host at runtime, not the engine.

#### Random  *(ctx: RandContext)*

| Signature | Description |
|---|---|
| `rand(lo, hi) -> f32xN` | uniform random per lane in `[lo, hi]`; result arity matches the arguments (`f32`, `f32x3`, `f32x4`, …) |
| `vrand() -> f32x3` | a random direction vector |

#### Samplers

| Signature | ctx | Description |
|---|---|---|
| `sampler.sample(uv) -> f32xN` | (SceneCtx for spatial/texture) | sample a curve/texture; result arity = the sampler's channel count |
| `sampler.samplePosition() -> f32x3` | RandCtx | a random point inside a shape sampler |
| `sampler.projectPCoords(localPos: f32x3) -> i32x3` | pCtxN | the shape's **parametric coordinates** of the surface point nearest `localPos` — an opaque address, not a position |
| `sampler.sampleNormal(pcoords: i32x3) -> f32x3` | — | the unit surface normal at those parametric coordinates |
| `sampler.sampleVelocity(pcoords: i32x3) -> f32x3` | pCtxI | the surface velocity there — an ANIMATED shape sampler only (`samplerShape_2I`) |
| `sampler.sampleTexcoord(pcoords: i32x3) -> f32x2` | — | the UV at those parametric coordinates |
| `sampler.sampleTangent(pcoords: i32x3) -> f32x4` | — | the surface tangent at those parametric coordinates |
| `sampler.project(localPos: f32x3) -> f32x4` | pCtxN | the point of the shape nearest `localPos`, projected onto its surface |
| `sampler.contains(localPos: f32x3) -> bool` | pCtxN | whether `localPos` is inside the shape |
| `sampler.samplePCoords() -> i32x3` | RandCtx | random parametric coordinates on the shape — `samplePosition()` without resolving them |
| `sampler.sampleSurfacePCoordsFromUV(uv: f32x2) -> i32x3` | pCtxN | the parametric coordinates a UV lands on |
| `sampler.sampleDensity(a, b) -> f32x2` | RandCtx | importance-sample a texture by its density (`samplerTexture13C`) |
| `sampler.sampleCDF(cursor: f32) -> f32` | — | a CDF curve's INVERSE — feed a uniform cursor, get the distributed value |
| `sampler.intersect(a, b, c, d) -> f32x4` | pCtxN | ray/shape intersection against a shape sampler |
| `sampler.duration() -> f32` | pCtxI | an event-stream sampler's timeline length |

`samplePosition` has a second overload taking the `i32x3` parametric coordinates, which resolves them
to the surface position. Sampling the position and the normal from the **same** coordinate is what
keeps the point and its normal consistent; the shape sampler works in the shape's **local** space, so
both the input and the two results need transforming (§15.4, Transforms). `stdlib/physics.cfx`'s
`physics.projection` is the whole sequence written out.

#### Emission counters  *(ctx: ParticleContextS)*

| Signature | Description |
|---|---|
| `event.generate(accum: i32x2, offsets, intervals, startTimes, endTimes) -> i32x3` | rate-based spawn counter; feed the returned `i32x3` to `initPayload` and write `accum = result.xy` back |
| `eventStream.generate(accum: i32x2, t0, t1, startTime, endTime) -> i32x3` | timeline-driven spawn counter (from an EventStream sampler) |
| `trigger(condition: bool, timeFraction: f32) -> i32x3` | one-shot: emits when `condition` is true |

The returned `i32x3` carries the new carry, the running total, and a generator cache key; its
whole-number part is this frame's spawn count. See [Emission](#10-emission).

#### Payloads

| Signature | ctx | Description |
|---|---|---|
| `event.initPayload(key: i32, eventKey: i32x3) -> i32` | pCtxS | park a spawn count under the event, in the table `key` names (one key per emission of a program); returns the payload key |
| `event.kick(key: i32) -> void` | RandCtx, pCtxS | fire the event → subscriber layers spawn |
| `buildPayloadElement(a, b, c, d) -> i32` | pCtxS | compute + register one payload element (the parent's per-child data) |
| `buildPayloadElementD(a, b, c, d, e, f) -> i32` | pCtxS | the same with the two extra DERIVATIVE arguments `VectorCubic` interpolation needs |
| `event.appendPayload(buildKey, element, elementIndex) -> i32` | pCtxS | attach a payload element to the event's payload |
| `extractPayloadElementF1(idx: i32) -> f32` | pCtxS | (child side) read payload element `idx` as an `f32` |
| `extractPayloadElementF3(idx: i32) -> f32x3` | pCtxS | …as a `f32x3` |
| `extractPayloadElementF4(idx: i32) -> f32x4` | pCtxS | …as a `f32x4` |
| `extractPayloadElementI1(idx: i32) -> i32` | pCtxS | …as an `i32` |
| `extractPayloadElementO(idx: i32) -> orientation` | pCtxS | …as an orientation/quaternion |

See [Payloads](#12-payloads) for the full parent→child chain.

#### Spatial layers

| Signature | ctx | Description |
|---|---|---|
| `spatial.allocatePayload() -> i32` | pCtxS | reserve a payload slot; returns a scratch key |
| `spatial.insert(a, b) -> void` | pCtxS | add this particle's position to the grid |
| `spatial.closestF3(center, radius, p0, p1, p2, p3) -> f32x3` | SceneCtx | the closest neighbour's payload within `radius` (or `+inf` if none) |
| `spatial.sumKernelF4(center, radius, p0, p1) -> f32x4` | SceneCtx, pCtxN | the kernel-weighted sum of the neighbours' payloads within `radius` |

#### Transforms & orientation

| Signature | ctx | Description |
|---|---|---|
| `xform_l2w_f_masked(v: f32x3, mask: i32) -> f32x3` | pCtxS | local → world transform (float); `mask` selects components |
| `xform_w2l_f_masked(v: f32x3, mask: i32) -> f32x3` | pCtxS | world → local |
| `xform_l2w_d_masked` / `xform_w2l_d_masked` | pCtxS | double-precision variants |
| `xform_w2w_f_masked(v: f32x3, mask: i32) -> f32x3` | pCtxS | world → world: the transform between the effect's previous frame and this one |
| `orientation_axisSide(v: f32x3) -> f32x3` | — | side-axis of an orientation |
| `orientation_axisUp(v: f32x3) -> f32x3` | — | up-axis of an orientation |
| `orientation_axisForward(o: orientation) -> f32x3` | — | forward-axis of an orientation |
| `rotate(a, b) -> f32x3` | — | rotate a vector |
| `radians.rotate(a, b, c) -> f32x3` | — | rotate about an axis by an angle (radians) |

#### Color

| Signature | Description |
|---|---|
| `hsv2rgb(v: f32x4) -> f32x4` | HSV → RGB |
| `rgb2hsv(v: f32x4) -> f32x4` | RGB → HSV |

#### Lifecycle  *(ctx: ParticleContextS)*

| Signature | Description |
|---|---|
| `self.kill(cond: bool) -> void` | kill this particle when `cond` is true |

#### Structural expression forms

Not calls, but part of the expression grammar:

| Form | Meaning |
|---|---|
| `#f32x3(1, 0, 0)` / `#i32x2(0, 0)` | inline vector constant (all-literal); with a non-literal component it's a constructor |
| `v.xyz` / `v.xxxx` | swizzle (component select / broadcast) |
| `ctor<f32x4>(a, b, c, d)` | build a vector from parts |
| `transmute::<T>(x)` | Rust-style bit cast — reinterprets the bits as `T` (e.g. `orientation`↔`f32x4`). The legacy `reint<dst\|src>(x)` form still parses |
| `x as T` | Rust-style cast — value conversion between types (e.g. `i32`↔`f32`). Repeatable: `x as f32 as i32`. The legacy `conv<dst\|src>(x)` form still parses |
| `select(cond, a, b)` | branchless `cond ? a : b` |

### 15.5 Common externals

| Name | Meaning |
|---|---|
| `self.lifeRatio` | age / lifetime, in `[0,1]`; `≥ 1.0` ⇒ dead |
| `self.invLife` | 1 / lifetime (`inf` ⇒ die next frame) |
| `self.metaData` | per-particle scratch slot (compiler-allocated; flagged by `metaData;` in the layer's `properties`, §8.1) |
| `scene.time`, `scene.dt` | scene clock; frame delta-time |
| `Position`, `Rotation`, `Color`, `Size`, `Velocity`, `Orientation` | particle render fields |
| `internal_HHHHHHHH` | persisted hidden state |
| `ParticleContextS/I/N`, `RandContext`, `SceneContext` | engine contexts (auto-supplied to calls) |

---

### Editing workflow

1. `cornsyrup decompile effect.pkb out.cfxb` → a bundle folder.
2. Edit the `.cfx` files (a curve in `samplers.cfx`, a formula in `code.cfx`, a color in a renderer…).
   `cornsyrup check out.cfxb` says whether the bundle builds, and why not, without writing anything.
3. `cornsyrup build out.cfxb rebuilt.pkb` → a runtime-identical (or edited-behavior) `.pkb`.

Because the round-trip is lossless, an unedited rebuild is a no-op; every difference in the rebuilt
effect comes from a change you made.

### Tools

CornSyrup ships four branded executables; the three graphical ones are dark-themed and localized
into 10 languages:

- **`cornsyrup`** — the command-line converter: `decompile`, `build`, `check` and `version`
  (`cornsyrup --help`). On Windows the `.exe` carries the CornSyrup icon in Explorer, the taskbar,
  and Alt-Tab. The development commands — `blob mesh`, the corpus gates, the blob dumps — are in
  `cornsyrup-dev`, which is built from the source rather than shipped.
- **`cornsyrup-ui`** — a graphical front-end for the same decompile/build round-trip.
- **`cornsyrup-tools`** — the individual editors, one per data kind: Curve, Gradient, Double Curve,
  Shape (including Mesh, §5.3), Vector Field (§5.2), Texture, Event Stream, Text, Renderer, Script.
- **`cornsyrup-mill`** — the effect IDE the other tools are parts of: it opens and saves CFX bundles,
  imports and exports `.pkb`, and edits everything through six workspaces — Preview, Graph, Functions,
  Renderers, Samplers, Header — beside two that are not about the document: Library (the installed
  CFX library) and Settings. Its Tools menu holds the **PKMM Baker** (MDX/MDL → `.pkmm`) and the
  **PKVF Baker** (`.fga` → `.pkvf`). Its one architectural commitment is that **CFX is the only
  internal representation**: a `.pkb` is converted on import and on export and never held, so every
  workspace edits text that CornSyrup's own parsers already read and write.

> **This guide is machine-read.** The editors' hover documentation parses §15.4 and §15.3 out of
> `CFX_GUIDE.md` at compile time — `builtins::sigs()` knows a builtin's arity and result type but has
> no parameter names and no prose, and this is the only place those exist. A test
> (`every_documented_builtin_agrees_with_the_signature_table`) fails if the two ever disagree, so
> editing a signature row here is editing the tooltip.
