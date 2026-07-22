defmodule LanternS3.Uploader.S3Adapter do
  @moduledoc """
  Reference `LanternS3.Uploader.Adapter` that prepares direct-to-S3 PUT uploads.

  ## Config

  `config` is a map with:

    * `:storage_adapter` — a module implementing `LanternS3.Storage`
    * `:storage_config` — opaque config for that storage adapter
    * `:bucket` — target bucket name
    * `:prefix` — optional key prefix (default `""`); concatenated with the
      entry filename to form the object key

  Returns `{:ok, %{uploader: "S3", key: key, url: url}}` so the bundled
  `S3` JS uploader can PUT the file body to the presigned URL.
  """

  @behaviour LanternS3.Uploader.Adapter

  @impl true
  def presign(config, entry, _opts) do
    prefix = Map.get(config, :prefix, "") || ""
    key = prefix <> entry.filename

    case config.storage_adapter.presigned_put(
           config.storage_config,
           config.bucket,
           key,
           content_type: entry.content_type,
           expires_in: 3600
         ) do
      {:ok, url} ->
        {:ok, %{uploader: "S3", key: key, url: url}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
