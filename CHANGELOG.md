# Changelog

All notable changes are documented here ([Keep a Changelog](https://keepachangelog.com),
[SemVer](https://semver.org)).

## [Unreleased]

### Added
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
