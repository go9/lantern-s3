defmodule LanternS3.Storage do
  @moduledoc """
  Behaviour for the file-manager viewer's data layer.

  This is the OSS-extractable storage contract for an upcoming LiveView bucket
  viewer. Implementations are thin, well-typed wrappers over an S3-compatible
  object store. They MUST NOT call any host-app context and MUST NOT read
  global application config internally: every callback receives an opaque
  per-call `config` (e.g. `LanternS3.Storage.S3.Config`) as its first
  argument, so the entire layer is configuration-injected and portable.

  ## Listing model

  `list/4` presents a single directory level: it groups keys by the `"/"`
  delimiter into `folders` (from S3 common prefixes) and `files` (leaf objects),
  with names stripped of the requested `prefix`. Pagination is opaque via
  `next_token` (an S3 continuation token) and `truncated?`.

  ## Non-atomic recursive operations

  `move/4`, `move_prefix/4`, and `delete_prefix/3` are deliberately
  **non-atomic**: there is no transactional guarantee across the many
  underlying object operations they perform. They never raise mid-walk;
  instead they return an `t:op_report/0` summarising what succeeded and what
  failed (with a per-key `reason`). A key that was successfully copied but
  whose source delete failed is an orphaned duplicate and is reported with
  `reason: :copy_ok_delete_failed`.
  """

  @typedoc """
  A directory-level listing.

    * `:folders` — child "directories" derived from common prefixes.
    * `:files` — leaf objects at this level.
    * `:next_token` — opaque continuation token for the next page, or `nil`.
    * `:truncated?` — whether more results exist beyond this page.
  """
  @type listing :: %{
          folders: [folder()],
          files: [file()],
          next_token: String.t() | nil,
          truncated?: boolean()
        }

  @typedoc "A folder entry: full `prefix` plus its `name` (last path segment)."
  @type folder :: %{prefix: String.t(), name: String.t()}

  @typedoc "A file entry with metadata; `name` is the key stripped of the listing prefix."
  @type file :: %{
          key: String.t(),
          name: String.t(),
          size: non_neg_integer(),
          last_modified: String.t(),
          etag: String.t()
        }

  @typedoc """
  The result of a non-atomic, possibly-recursive bulk operation.

    * `:total` — number of objects the operation attempted to act on.
    * `:succeeded` — number that completed fully.
    * `:failed` — per-key failures, each with the underlying `reason`. The
      special reason `:copy_ok_delete_failed` marks an orphaned duplicate
      (copy succeeded but the source delete did not).
  """
  @type op_report :: %{
          total: non_neg_integer(),
          succeeded: non_neg_integer(),
          failed: [%{key: String.t(), reason: term()}]
        }

  @typedoc "Opaque per-call connection config (e.g. `LanternS3.Storage.S3.Config`)."
  @type config :: term()

  @doc "Lists the buckets visible to the credentials in `config`."
  @callback list_buckets(config()) :: {:ok, [%{name: String.t()}]} | {:error, term()}

  @doc "Lists one directory level under `prefix` in `bucket`."
  @callback list(config(), bucket :: String.t(), prefix :: String.t(), opts :: keyword()) ::
              {:ok, listing()} | {:error, term()}

  @doc "Returns a presigned GET URL for `key`."
  @callback presigned_get(config(), bucket :: String.t(), key :: String.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @doc "Returns a presigned PUT URL for `key`."
  @callback presigned_put(config(), bucket :: String.t(), key :: String.t(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @doc "Writes an object (used for zero-byte folder markers)."
  @callback put_object(
              config(),
              bucket :: String.t(),
              key :: String.t(),
              body :: binary(),
              opts :: keyword()
            ) :: {:ok, map()} | {:error, term()}

  @doc "Fetches object metadata (HEAD)."
  @callback head(config(), bucket :: String.t(), key :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @doc "Server-side copies `src_key` to `dest_key` within `bucket`."
  @callback copy(config(), bucket :: String.t(), src_key :: String.t(), dest_key :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @doc "Deletes up to many keys, chunked at the S3 1000-per-request limit."
  @callback delete_many(config(), bucket :: String.t(), keys :: [String.t()]) ::
              {:ok, %{deleted: [String.t()], errors: [map()]}} | {:error, term()}

  @doc "Non-atomic copy+delete of a single object. Returns an `t:op_report/0`."
  @callback move(config(), bucket :: String.t(), src_key :: String.t(), dest_key :: String.t()) ::
              {:ok, op_report()} | {:error, term()}

  @doc "Non-atomic recursive move of every object under `src_prefix`. Returns an `t:op_report/0`."
  @callback move_prefix(
              config(),
              bucket :: String.t(),
              src_prefix :: String.t(),
              dest_prefix :: String.t()
            ) :: {:ok, op_report()} | {:error, term()}

  @doc "Non-atomic recursive delete of every object under `prefix`. Returns an `t:op_report/0`."
  @callback delete_prefix(config(), bucket :: String.t(), prefix :: String.t()) ::
              {:ok, op_report()} | {:error, term()}
end
