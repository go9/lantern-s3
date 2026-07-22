# Changelog

All notable changes are documented here ([Keep a Changelog](https://keepachangelog.com),
[SemVer](https://semver.org)).

## [Unreleased]

### Added
- Initial extraction from the flicker monorepo (provenance: `orlando-umbrella/flicker`
  `lib/lantern_s3`). `LanternS3.Explorer` (bucket viewer / file manager) and
  `LanternS3.Uploader` (drag-drop uploader) LiveComponents, the `LanternS3.Storage`
  behaviour + S3 adapter, `LanternS3.Uploader.Adapter` behaviour + `S3Adapter`,
  `LanternS3.Scope`, `LanternS3.Errors`; the `S3` JS uploader hook and the component
  stylesheet ship in `priv/static/`.
