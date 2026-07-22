defmodule LanternS3.Uploader.Adapter do
  @moduledoc """
  Behaviour for preparing a direct (external) browser upload.

  `LanternS3.Uploader` is storage-agnostic: it never talks to S3 (or any other
  backend) itself. Consumers implement this behaviour and inject the module via
  the component's `:adapter` assign. When LiveView needs a presigned target for
  an entry, the component calls `presign/3` and relays the returned meta map to
  the registered JS uploader.

  ## Meta contract

  A successful return must be `{:ok, meta}` where `meta` is a map that includes:

    * `:uploader` — the key of a JS uploader registered on the LiveSocket
      (e.g. `"S3"` for the bundled `s3_uploader.js` PUT helper)
    * `:key` — the object key that will be harvested on completion
    * whatever else the JS uploader needs (for the S3 uploader: `:url`)

  Errors are returned as `{:error, reason}`; the component surfaces a string
  form of `reason` on the entry and does not crash.
  """

  @type entry :: %{filename: String.t(), content_type: String.t()}

  @doc """
  Prepare a direct upload for `entry`.

  `config` is an opaque term supplied by the host as the component's
  `:adapter_config` assign and passed through verbatim. `opts` is reserved for
  future use (currently always `[]`).
  """
  @callback presign(config :: term(), entry :: entry(), opts :: keyword()) ::
              {:ok, meta :: map()} | {:error, term()}
end
