# OpenXE Roadmap

OpenXE deliberately does a small number of things well. This note records what is
planned, what is explicitly out of scope, and the known risks — so contributors know
where help is welcome and where a "no" is intentional.

The binding scope decisions live in the design spec:
[`docs/design/specs/2026-07-06-openxe-design.md`](design/specs/2026-07-06-openxe-design.md)
(§8 Risks, §10 Out of Scope). This roadmap summarizes and links them.

## Working today

- Double-click `.exe` → runs, first-run engine download, persistent prefix,
  Wine Mono + Gecko, per-app settings, font provisioning, native Dock identity,
  multi-engine swap. See the README for the full list.
- New World Scheduler 8.1 and 8.2 main UI, under software rendering.

## Planned — GPU / maps acceleration

**Status: planned, not started. Separate effort from the runner itself.**

New World Scheduler's secondary **map / 3D view** wants hardware rendering. OpenXE
currently ships **no GPU backend**, so WPF is forced onto its software render tier
(`Avalon.Graphics\DisableHWAcceleration=1`) — which makes the **main scheduler UI
fully usable**, but leaves the map view unaccelerated.

Bringing up the GPU/maps stack means, per the spec's §8 escalation criterion:

- Bundle **x86_64** MoltenVK (`libvulkan.1.dylib` / `libMoltenVK.dylib`) — note
  **x86_64, not arm64**: the Wine loader runs under Rosetta, so an arm64 Vulkan
  cannot load into it.
- Add a **D3D → Vulkan/Metal** translation layer — **DXVK** or **DXMT / D3DMetal**.
- A deliberate, separate scope decision on footprint, licensing, and build.

This is intentionally decoupled from the runner: the main UI does not depend on it,
and a separate effort owns the graphics stack. Reference: design spec §8, risks 7–8.

## Planned — networked Windows-side TLS

The default engine is built `--without-gnutls`. Local licensing works; any feature
needing real Windows-side TLS (activation/update/sync over schannel) needs an engine
rebuilt `--with-gnutls` (adds an x86_64 gnutls dependency). This is an engine-build
scope item, not a runner change. Reference: design spec §8, risk 8.

## Known risk — Rosetta 2 sunset (macOS 28)

The current engine is x86_64-only and depends on **Rosetta 2**, which Apple has
signaled for retirement in **macOS 28 (fall 2027)**. This is the single biggest risk
to the project. The hedge is architectural: the engine is **versioned and swappable**
behind the `engine/current` contract, so an **arm64-native Wine** build drops in
without touching the rest of the app. No arm64 engine is pinned or verified today —
sourcing/validating one is a future work item, and a natural place for community help.
Reference: design spec §8, risk 1.

## Explicitly out of scope (by design)

From the design spec §10 — these are deliberate "no"s, not backlog:

- DirectX / gaming stack tuning, game controllers (beyond the maps escalation above).
- Multiple prefixes / separate bottles, and per-app **engine** selection (per-app
  Windows version + DLL overrides *are* supported, in the shared prefix).
- Library UI, menu-bar item, Dock presence while idle.
- Notarization, auto-update framework (the swappable engine is the only update
  surface; the app is ad-hoc signed).
- Any third-party Swift dependency.

If you want one of these, open an issue to discuss the trade-off first — but expect
the bar to be "what breaks if we don't build this?"

## Where help is most welcome

- **App compatibility reports** — try apps, tell us what works / breaks (use the
  compatibility issue template).
- **Font substitution table** improvements in `FontProvisioning.swift`.
- **The GPU/maps stack** (large, separate effort — coordinate via an issue first).
- **An arm64-native engine** path for the Rosetta sunset.
