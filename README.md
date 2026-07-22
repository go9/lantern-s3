# LanternS3

A host-agnostic **S3 file manager** (`LanternS3.Explorer`) and **drag-drop uploader**
(`LanternS3.Uploader`) as Phoenix LiveComponents. Extracted from the flicker monorepo.

Everything is injected via a `%LanternS3.Scope{}` (storage adapter, opaque config, allowed
buckets, capabilities, an optional `on_event` audit seam) — the components never read global
config and carry no host references.

## Install

```elixir
def deps do
  [{:lantern_s3, github: "go9/lantern-s3"}]
end
```

## Host requirements

1. **Lantern stylesheet** — components use the `.lantern` design system (`lt-*` / `--lt-*`).
   Import the shipped stylesheet in your `app.css`:

   ```css
   @import "../../deps/lantern_s3/priv/static/lantern_s3.css";
   ```

2. **Heroicons** — icons render as `hero-*` utility classes; your Tailwind build must include
   the heroicons plugin.

3. **JS uploader hook** — register the direct-to-S3 uploader (key must match the adapter's
   `meta.uploader`) and the download hook:

   ```js
   import { S3, LanternS3Download } from "../../deps/lantern_s3/priv/static/lantern_s3_uploader"
   let liveSocket = new LiveSocket("/live", Socket, {
     uploaders: { S3 },
     hooks: { LanternS3Download, /* ... */ }
   })
   ```

4. **ex_aws** — the S3 storage adapter (`LanternS3.Storage.S3`) uses `ex_aws`/`ex_aws_s3`;
   configure its HTTP client + credentials per your app (config is passed per-call via `Scope`,
   never read from `Application.get_env`).

## Usage

```elixir
<.live_component
  module={LanternS3.Explorer}
  id="files"
  scope={LanternS3.Scope.new(
    adapter: LanternS3.Storage.S3,
    config: my_s3_config,
    buckets: [%{name: "media", label: "Media"}],
    capabilities: :all,
    on_event: &audit/2
  )}
/>
```

Write your own `LanternS3.Storage` adapter for non-S3 backends, or your own
`LanternS3.Uploader.Adapter` to control presigning.

## License

MIT.
