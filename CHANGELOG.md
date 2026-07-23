# Changelog

All notable changes are documented here ([Keep a Changelog](https://keepachangelog.com),
[SemVer](https://semver.org)).

## [Unreleased]

### Added
- **Uploader opens in a slide-over sheet over the table** (scoped to the
  Explorer itself, not the viewport) — the Explorer's
  Upload overlays the file listing from the right (backdrop + close) instead of
  replacing it; the listing stays visible and re-lists behind the sheet as
  uploads complete.
- **Self-contained icons** — `lantern_s3.css` now bundles mask-image rules for
  every `hero-*` icon the package renders (Heroicons, MIT). No host Tailwind
  build required; hosts running the heroicons plugin get identical rules.
- **Injectable upload adapter + limits** on `Scope` (`upload_adapter`, `upload_opts`):
  the Explorer's built-in uploader can now use a host-supplied presign adapter
  (e.g. a gated one) and accept/max-entries/max-file-size, instead of the fixed
  default. Lets one Explorer be the whole interface even where uploads must be
  policy-enforced (public sandbox). Defaults preserve current behaviour.
- **`Scope.root_prefix`** — confine an Explorer mount to a subtree. The browser
  starts at the root, `navigate` is guarded (`Scope.within_root?/2`) so a client
  can never steer above/outside it, and the breadcrumb is relative to the root.
  Enables multi-tenant "browse only your own prefix" mounts (e.g. a shared bucket
  where each session sees just `sessions/<id>/`). Defaults to `""` (whole bucket),
  so existing mounts are unaffected.
- Initial extraction from the flicker monorepo (provenance: `orlando-umbrella/flicker`
  `lib/lantern_s3`). `LanternS3.Explorer` (bucket viewer / file manager) and
  `LanternS3.Uploader` (drag-drop uploader) LiveComponents, the `LanternS3.Storage`
  behaviour + S3 adapter, `LanternS3.Uploader.Adapter` behaviour + `S3Adapter`,
  `LanternS3.Scope`, `LanternS3.Errors`; the `S3` JS uploader hook and the component
  stylesheet ship in `priv/static/`.
