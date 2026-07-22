defmodule LanternS3.Storage.S3 do
  @moduledoc """
  ExAws-backed implementation of `LanternS3.Storage` for S3-compatible stores.

  This module is intentionally OSS-extractable: it never touches a host-app
  context and never reads global application config. Every function takes a
  `LanternS3.Storage.S3.Config` struct as its first argument and builds a
  *per-call* `ExAws.Config` from it via `ExAws.Config.new/2`. The global
  `config :ex_aws` application environment is deliberately NOT used for
  credentials, so two callers with different credentials/endpoints never
  interfere.

  It is a thin wrapper over `ExAws.S3` operations
  (`list_objects_v2`, `list_buckets`, `put_object_copy`,
  `delete_multiple_objects`, `head_object`, `put_object`, `presigned_url`) — no
  `Req` and no hand-rolled HTTP.

  ## Non-atomicity

  `move/4`, `move_prefix/4`, and `delete_prefix/3` are NON-ATOMIC. They walk
  many objects, never raise mid-walk, and return a `t:LanternS3.Storage.op_report/0`
  describing partial success. A key copied successfully but whose source delete
  failed is reported with `reason: :copy_ok_delete_failed` (an orphaned
  duplicate the caller may wish to retry).
  """

  @behaviour LanternS3.Storage

  alias LanternS3.Storage.S3.Config

  import SweetXml, only: [sigil_x: 2]

  @type op_report :: LanternS3.Storage.op_report()

  # S3 caps a single DeleteObjects request at 1000 keys.
  @delete_chunk_size 1000
  # Default page size for directory listings.
  @default_max_keys 200

  @impl LanternS3.Storage
  def list_buckets(%Config{} = config) do
    case ExAws.S3.list_buckets() |> request(config) do
      {:ok, %{body: %{buckets: buckets}}} when is_list(buckets) ->
        {:ok, Enum.map(buckets, fn b -> %{name: b.name} end)}

      {:ok, _} ->
        {:ok, []}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl LanternS3.Storage
  def list(%Config{} = config, bucket, prefix, opts \\ []) do
    prefix = normalize_prefix(prefix)
    max_keys = Keyword.get(opts, :max_keys) || @default_max_keys
    continuation_token = Keyword.get(opts, :continuation_token)

    list_opts =
      [delimiter: "/", prefix: prefix, max_keys: max_keys]
      |> maybe_put(:continuation_token, continuation_token)

    case ExAws.S3.list_objects_v2(bucket, list_opts) |> request(config) do
      {:ok, %{body: body}} ->
        {:ok, build_listing(body, prefix)}

      {:error, error} ->
        {:error, error}
    end
  end

  @impl LanternS3.Storage
  def presigned_get(%Config{} = config, bucket, key, opts \\ []) do
    presigned(config, :get, bucket, key, opts)
  end

  @impl LanternS3.Storage
  def presigned_put(%Config{} = config, bucket, key, opts \\ []) do
    presigned(config, :put, bucket, key, opts)
  end

  @impl LanternS3.Storage
  def put_object(%Config{} = config, bucket, key, body \\ "", opts \\ []) do
    ExAws.S3.put_object(bucket, key, body, opts) |> request(config)
  end

  @impl LanternS3.Storage
  def head(%Config{} = config, bucket, key) do
    ExAws.S3.head_object(bucket, key) |> request(config)
  end

  @impl LanternS3.Storage
  def copy(%Config{} = config, bucket, src_key, dest_key) do
    ExAws.S3.put_object_copy(bucket, dest_key, bucket, src_key) |> request(config)
  end

  @impl LanternS3.Storage
  def delete_many(%Config{} = config, bucket, keys) when is_list(keys) do
    result =
      keys
      |> Enum.chunk_every(@delete_chunk_size)
      |> Enum.reduce_while({:ok, %{deleted: [], errors: []}}, fn chunk, {:ok, acc} ->
        case ExAws.S3.delete_multiple_objects(bucket, chunk) |> request(config) do
          {:ok, %{body: body}} ->
            {deleted, errors} = parse_delete_result(body)

            {:cont,
             {:ok,
              %{
                deleted: acc.deleted ++ deleted,
                errors: acc.errors ++ errors
              }}}

          {:error, error} ->
            {:halt, {:error, error}}
        end
      end)

    result
  end

  @impl LanternS3.Storage
  def move(%Config{} = config, bucket, src_key, dest_key) do
    {:ok, move_one(config, bucket, src_key, dest_key, empty_report(1))}
  end

  @impl LanternS3.Storage
  def move_prefix(%Config{} = config, bucket, src_prefix, dest_prefix) do
    src_prefix = normalize_prefix(src_prefix)
    dest_prefix = normalize_prefix(dest_prefix)

    walk_prefix(config, bucket, src_prefix, fn key, report ->
      dest_key = dest_prefix <> String.replace_prefix(key, src_prefix, "")
      move_one(config, bucket, key, dest_key, report)
    end)
  end

  @impl LanternS3.Storage
  def delete_prefix(%Config{} = config, bucket, prefix) do
    prefix = normalize_prefix(prefix)

    walk_prefix(config, bucket, prefix, fn key, report ->
      case ExAws.S3.delete_object(bucket, key) |> request(config) do
        {:ok, _} -> record_success(report)
        {:error, reason} -> record_failure(report, key, reason)
      end
    end)
  end

  # --- listing helpers -------------------------------------------------------

  defp build_listing(body, prefix) do
    folders =
      body
      |> Map.get(:common_prefixes, [])
      |> List.wrap()
      |> Enum.map(& &1.prefix)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.map(fn folder_prefix ->
        %{prefix: folder_prefix, name: folder_name(folder_prefix, prefix)}
      end)

    files =
      body
      |> Map.get(:contents, [])
      |> List.wrap()
      |> Enum.map(&map_content/1)
      # Exclude the zero-byte folder-marker object whose key IS the prefix.
      |> Enum.reject(fn file -> file.key == prefix end)

    %{
      folders: folders,
      files: files,
      next_token: empty_to_nil(Map.get(body, :next_continuation_token)),
      truncated?: truthy?(Map.get(body, :is_truncated))
    }
  end

  defp map_content(content) do
    key = Map.get(content, :key, "")

    %{
      key: key,
      name: strip_prefix_name(key),
      size: parse_int(Map.get(content, :size)),
      last_modified: Map.get(content, :last_modified, ""),
      etag: Map.get(content, :e_tag, "")
    }
  end

  # The folder name is the last path segment of the common prefix, with the
  # listing prefix and trailing slash removed.
  defp folder_name(folder_prefix, list_prefix) do
    folder_prefix
    |> String.replace_prefix(list_prefix, "")
    |> String.trim_trailing("/")
  end

  defp strip_prefix_name(key) do
    key
    |> String.split("/")
    |> List.last()
    |> Kernel.||("")
  end

  # --- presigned helpers -----------------------------------------------------

  defp presigned(config, method, bucket, key, opts) do
    aws_config = aws_config(config)

    presign_opts =
      opts
      |> Keyword.take([:expires_in, :query_params, :virtual_host])
      |> maybe_put_content_type(opts)

    ExAws.S3.presigned_url(aws_config, method, bucket, key, presign_opts)
  end

  # Surface a requested content_type as a signed query param so the presigned
  # PUT enforces it, mirroring how callers expect to constrain uploads.
  defp maybe_put_content_type(presign_opts, opts) do
    case Keyword.get(opts, :content_type) do
      nil ->
        presign_opts

      content_type ->
        existing = Keyword.get(presign_opts, :query_params, [])
        Keyword.put(presign_opts, :query_params, existing ++ [{"Content-Type", content_type}])
    end
  end

  # --- recursive op helpers --------------------------------------------------

  # Lists every key under `prefix` (paginating until exhausted) and folds `fun`
  # over each one. Never raises mid-walk: a listing error short-circuits to
  # `{:error, reason}`, otherwise the accumulated `op_report` is returned.
  defp walk_prefix(config, bucket, prefix, fun) do
    do_walk(config, bucket, prefix, nil, fun, empty_report(0))
  end

  defp do_walk(config, bucket, prefix, token, fun, report) do
    list_opts =
      [prefix: prefix, max_keys: @delete_chunk_size]
      |> maybe_put(:continuation_token, token)

    case ExAws.S3.list_objects_v2(bucket, list_opts) |> request(config) do
      {:ok, %{body: body}} ->
        keys =
          body
          |> Map.get(:contents, [])
          |> List.wrap()
          |> Enum.map(&Map.get(&1, :key))
          |> Enum.reject(&(&1 in [nil, ""]))

        report =
          Enum.reduce(keys, %{report | total: report.total + length(keys)}, fn key, acc ->
            fun.(key, acc)
          end)

        if truthy?(Map.get(body, :is_truncated)) do
          next = Map.get(body, :next_continuation_token)
          do_walk(config, bucket, prefix, next, fun, report)
        else
          {:ok, report}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  # Copy then delete one object, folding the outcome into `report`.
  defp move_one(config, bucket, src_key, dest_key, report) do
    case ExAws.S3.put_object_copy(bucket, dest_key, bucket, src_key) |> request(config) do
      {:ok, _} ->
        case ExAws.S3.delete_object(bucket, src_key) |> request(config) do
          {:ok, _} -> record_success(report)
          # Orphaned duplicate: the copy landed but the source still exists.
          {:error, _} -> record_failure(report, src_key, :copy_ok_delete_failed)
        end

      {:error, reason} ->
        record_failure(report, src_key, reason)
    end
  end

  defp empty_report(total), do: %{total: total, succeeded: 0, failed: []}

  defp record_success(report), do: %{report | succeeded: report.succeeded + 1}

  defp record_failure(report, key, reason) do
    %{report | failed: report.failed ++ [%{key: key, reason: reason}]}
  end

  # --- delete-result parsing -------------------------------------------------

  # `delete_multiple_objects` has no built-in ExAws parser, so we parse the
  # <DeleteResult> XML body ourselves.
  defp parse_delete_result(body) when is_binary(body) do
    parsed =
      SweetXml.xpath(body, ~x"//DeleteResult",
        deleted: [~x"./Deleted"l, key: ~x"./Key/text()"s],
        errors: [
          ~x"./Error"l,
          key: ~x"./Key/text()"s,
          code: ~x"./Code/text()"s,
          message: ~x"./Message/text()"s
        ]
      )

    deleted = parsed |> Map.get(:deleted, []) |> Enum.map(& &1.key)

    errors =
      parsed
      |> Map.get(:errors, [])
      |> Enum.map(fn e -> %{key: e.key, code: e.code, message: e.message} end)

    {deleted, errors}
  end

  # Already-parsed bodies (defensive — e.g. an upstream parser change).
  defp parse_delete_result(%{} = body) do
    {Map.get(body, :deleted, []), Map.get(body, :errors, [])}
  end

  defp parse_delete_result(_), do: {[], []}

  # --- ExAws config + small utils --------------------------------------------

  defp request(operation, %Config{} = config) do
    ExAws.request(operation, aws_overrides(config))
  end

  defp aws_config(%Config{} = config) do
    ExAws.Config.new(:s3, aws_overrides(config))
  end

  # Build per-call ExAws config overrides from our struct. We never read the
  # global `config :ex_aws` env — these overrides fully specify the connection.
  defp aws_overrides(%Config{} = config) do
    [
      access_key_id: config.access_key_id,
      secret_access_key: config.secret_access_key,
      region: config.region,
      scheme: config.scheme,
      host: Config.host(config)
    ]
  end

  defp normalize_prefix(nil), do: ""
  defp normalize_prefix(""), do: ""

  defp normalize_prefix(prefix) when is_binary(prefix) do
    if String.ends_with?(prefix, "/"), do: prefix, else: prefix <> "/"
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp empty_to_nil(nil), do: nil
  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp truthy?("true"), do: true
  defp truthy?(true), do: true
  defp truthy?(_), do: false

  defp parse_int(nil), do: 0
  defp parse_int(int) when is_integer(int), do: int

  defp parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {int, _} -> int
      :error -> 0
    end
  end
end
