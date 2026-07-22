defmodule LanternS3.Scope do
  @moduledoc """
  The injected configuration that `LanternS3.Explorer` runs against.

  This struct is the *entire* coupling surface of the bucket viewer. The
  component never reads global application config, never calls a host-app
  context, and never references any host-app module — everything it needs
  arrives in a `%LanternS3.Scope{}` built by the host's LiveView mount. That keeps
  the component OSS-extractable into a standalone `lantern-s3` package.

  ## Fields

    * `:adapter` — a module implementing the `LanternS3.Storage` behaviour. Every
      object-store interaction goes through this module.
    * `:config` — opaque per-call connection config (e.g.
      `LanternS3.Storage.S3.Config`). Passed verbatim as the first argument to
      every adapter call; the component never inspects it.
    * `:buckets` — the *only* buckets this mount may open, each a
      `%{name: String.t(), label: String.t()}`. Isolation lives here: the
      component can never open a bucket that is not in this list. The host
      decides the list (admin = all buckets, a customer = their org's buckets).
    * `:capabilities` — a `MapSet` drawn from
      `#{inspect(__MODULE__)}.all_capabilities/0`. Write UI is gated on these,
      so a read-only mount drops upload/delete/move/rename/create-folder
      controls with zero component changes.
    * `:on_event` — optional 2-arity `fun(event_name, metadata)` the component
      calls for host audit/telemetry. The component knows nothing about what it
      does; `nil` disables the seam.
    * `:auto_open` — when `true` and the scope grants **exactly one** bucket, the
      component opens straight into that bucket's files instead of rendering a
      one-item bucket picker (the picker is pointless for a single bucket). With
      two or more buckets it has no effect: the picker still appears. Defaults to
      `false`, so existing hosts keep the picker-first behaviour unchanged.
  """

  @typedoc "A capability the host grants the component."
  @type capability ::
          :upload | :delete | :move | :rename | :create_folder | :download

  @type bucket :: %{name: String.t(), label: String.t()}

  @type t :: %__MODULE__{
          adapter: module(),
          config: term(),
          buckets: [bucket()],
          capabilities: MapSet.t(capability()),
          on_event: (atom(), map() -> any()) | nil,
          auto_open: boolean(),
          root_prefix: String.t(),
          upload_adapter: module() | nil,
          upload_opts: map()
        }

  @enforce_keys [:adapter, :config]
  defstruct adapter: nil,
            config: nil,
            buckets: [],
            capabilities: nil,
            on_event: nil,
            auto_open: false,
            root_prefix: "",
            upload_adapter: nil,
            upload_opts: %{}

  @all_capabilities MapSet.new([
                      :upload,
                      :delete,
                      :move,
                      :rename,
                      :create_folder,
                      :download
                    ])

  @doc "The full set of capabilities (everything a fully-privileged mount grants)."
  @spec all_capabilities() :: MapSet.t(capability())
  def all_capabilities, do: @all_capabilities

  @doc """
  Builds a scope from attributes.

  `:adapter` and `:config` are required. `:capabilities` accepts a `MapSet`, a
  list of capability atoms, or `:all` (the default), and is normalised to a
  `MapSet`. `:buckets` entries are normalised so each has both `:name` and
  `:label` (the label defaults to the name). `:auto_open` defaults to `false`.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      adapter: fetch!(attrs, :adapter),
      config: fetch!(attrs, :config),
      buckets: attrs |> Map.get(:buckets, []) |> Enum.map(&normalize_bucket/1),
      capabilities: normalize_capabilities(Map.get(attrs, :capabilities, :all)),
      on_event: Map.get(attrs, :on_event),
      auto_open: Map.get(attrs, :auto_open, false) == true,
      root_prefix: attrs |> Map.get(:root_prefix, "") |> normalize_root_prefix(),
      upload_adapter: Map.get(attrs, :upload_adapter),
      upload_opts: Map.get(attrs, :upload_opts, %{})
    }
  end

  @doc "The locked root prefix this mount is confined to (`\"\"` = the whole bucket)."
  @spec root_prefix(t()) :: String.t()
  def root_prefix(%__MODULE__{root_prefix: prefix}), do: prefix

  @doc """
  Whether `prefix` is at or below the scope's locked root — the navigation guard.

  With a `root_prefix` of `"sessions/abc/"`, a client-supplied `"sessions/xyz/"`
  (or `""`, the bucket root) is rejected, so the Explorer can never be steered
  out of the mount's own subtree. Always true when no root is set.
  """
  @spec within_root?(t(), String.t()) :: boolean()
  def within_root?(%__MODULE__{root_prefix: root}, prefix) when is_binary(prefix),
    do: String.starts_with?(prefix, root)

  def within_root?(_scope, _prefix), do: false

  @doc "Whether `capability` is granted by `scope`."
  @spec can?(t(), capability()) :: boolean()
  def can?(%__MODULE__{capabilities: caps}, capability) do
    MapSet.member?(caps, capability)
  end

  @doc """
  The single bucket to auto-open, or `nil`.

  Returns the lone bucket only when `:auto_open` is set **and** the scope grants
  exactly one bucket. In every other case (auto-open off, zero buckets, or two or
  more) it returns `nil` and the component renders the picker.
  """
  @spec auto_open_bucket(t()) :: bucket() | nil
  def auto_open_bucket(%__MODULE__{auto_open: true, buckets: [bucket]}), do: bucket
  def auto_open_bucket(%__MODULE__{}), do: nil

  defp fetch!(attrs, key) do
    case Map.get(attrs, key) do
      nil -> raise ArgumentError, "#{inspect(key)} is required to build a #{inspect(__MODULE__)}"
      value -> value
    end
  end

  defp normalize_bucket(%{name: name} = bucket) do
    %{name: name, label: Map.get(bucket, :label) || name}
  end

  defp normalize_bucket(name) when is_binary(name), do: %{name: name, label: name}

  defp normalize_capabilities(:all), do: @all_capabilities
  defp normalize_capabilities(%MapSet{} = caps), do: caps
  defp normalize_capabilities(caps) when is_list(caps), do: MapSet.new(caps)

  # Normalise to a bare, trailing-slashed key prefix: "" stays "" (whole bucket),
  # otherwise strip any leading slash and ensure exactly one trailing slash so it
  # composes cleanly with object keys and String.starts_with?/2 checks.
  defp normalize_root_prefix(nil), do: ""
  defp normalize_root_prefix(""), do: ""

  defp normalize_root_prefix(prefix) when is_binary(prefix) do
    trimmed = String.trim_leading(prefix, "/")
    if String.ends_with?(trimmed, "/"), do: trimmed, else: trimmed <> "/"
  end
end
