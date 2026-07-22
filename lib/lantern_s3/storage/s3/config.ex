defmodule LanternS3.Storage.S3.Config do
  @moduledoc """
  Connection configuration for `LanternS3.Storage.S3`.

  This struct is the *only* source of credentials and endpoint information for
  the S3 storage adapter. It is passed as the first argument to every adapter
  callback, which means the adapter never reads global application config or any
  host-app context: all configuration is injected by the caller (the
  LiveView mount). That keeps the storage layer OSS-extractable.

  ## Fields

    * `:access_key_id` — S3 access key id.
    * `:secret_access_key` — S3 secret access key.
    * `:region` — S3 region. Defaults to `"auto"` (Tigris / S3-compatible).
    * `:scheme` — URL scheme, including the trailing `"://"`. Defaults to
      `"https://"`.
    * `:host` — explicit host (e.g. `"t3.storage.dev"`). When `nil`, the
      default host is used unless `:endpoint_url` is set.
    * `:endpoint_url` — full endpoint URL (e.g. `"https://t3.storage.dev"`).
      When present, its host takes precedence over `:host`.

  ## Host resolution

  The effective host is resolved by `host/1` in this order:

      endpoint_url (host component) → host → default ("t3.storage.dev")

  The default is deliberately the off-Fly Tigris endpoint `t3.storage.dev`;
  the legacy `fly.storage.tigris.dev` host is never used.
  """

  @default_host "t3.storage.dev"
  @default_region "auto"
  @default_scheme "https://"

  @enforce_keys [:access_key_id, :secret_access_key]
  defstruct access_key_id: nil,
            secret_access_key: nil,
            region: @default_region,
            scheme: @default_scheme,
            host: nil,
            endpoint_url: nil

  @type t :: %__MODULE__{
          access_key_id: String.t(),
          secret_access_key: String.t(),
          region: String.t(),
          scheme: String.t(),
          host: String.t() | nil,
          endpoint_url: String.t() | nil
        }

  @doc """
  Builds a `%Config{}` from a keyword list or map of attributes.

  Required keys: `:access_key_id`, `:secret_access_key`. Optional keys fall back
  to their defaults (`region: "auto"`, `scheme: "https://"`, `host: nil`,
  `endpoint_url: nil`).

  ## Examples

      iex> LanternS3.Storage.S3.Config.new(access_key_id: "AK", secret_access_key: "SK")
      %LanternS3.Storage.S3.Config{
        access_key_id: "AK",
        secret_access_key: "SK",
        region: "auto",
        scheme: "https://",
        host: nil,
        endpoint_url: nil
      }
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      access_key_id: fetch!(attrs, :access_key_id),
      secret_access_key: fetch!(attrs, :secret_access_key),
      region: Map.get(attrs, :region) || @default_region,
      scheme: Map.get(attrs, :scheme) || @default_scheme,
      host: Map.get(attrs, :host),
      endpoint_url: Map.get(attrs, :endpoint_url)
    }
  end

  @doc """
  Resolves the effective host for the given config.

  Resolution order: the host component of `:endpoint_url`, then `:host`, then
  the default `"t3.storage.dev"`.

  ## Examples

      iex> LanternS3.Storage.S3.Config.host(%LanternS3.Storage.S3.Config{
      ...>   access_key_id: "AK", secret_access_key: "SK"
      ...> })
      "t3.storage.dev"

      iex> LanternS3.Storage.S3.Config.host(%LanternS3.Storage.S3.Config{
      ...>   access_key_id: "AK", secret_access_key: "SK", host: "custom.example.com"
      ...> })
      "custom.example.com"

      iex> LanternS3.Storage.S3.Config.host(%LanternS3.Storage.S3.Config{
      ...>   access_key_id: "AK",
      ...>   secret_access_key: "SK",
      ...>   endpoint_url: "https://endpoint.example.com:9000"
      ...> })
      "endpoint.example.com"
  """
  @spec host(t()) :: String.t()
  def host(%__MODULE__{endpoint_url: endpoint_url, host: explicit_host})
      when is_binary(endpoint_url) do
    case endpoint_host(endpoint_url) do
      host when is_binary(host) and host != "" -> host
      _ when is_binary(explicit_host) and explicit_host != "" -> explicit_host
      _ -> @default_host
    end
  end

  def host(%__MODULE__{host: host}) when is_binary(host) and host != "", do: host
  def host(%__MODULE__{}), do: @default_host

  @doc "The default host used when neither `:endpoint_url` nor `:host` is set."
  @spec default_host() :: String.t()
  def default_host, do: @default_host

  defp fetch!(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        raise ArgumentError, "#{inspect(key)} is required to build a #{inspect(__MODULE__)}"
    end
  end

  defp endpoint_host(endpoint_url) do
    case URI.parse(endpoint_url) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      # No scheme/host parsed (e.g. a bare "host:port") — fall back to the path.
      %URI{path: path} when is_binary(path) and path != "" -> path |> String.split(":") |> hd()
      _ -> nil
    end
  end
end
