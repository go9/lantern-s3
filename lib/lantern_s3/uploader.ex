defmodule LanternS3.Uploader do
  @moduledoc """
  A self-contained drag-and-drop file uploader as a `Phoenix.LiveComponent`.

  ## OSS-extraction contract

  Portable into a standalone `lantern-s3` hex package. Constraints:

    * `use`s `Phoenix.LiveComponent` directly — never a host `:live_component` macro
    * No host-app references, no global application config, no host UI components
    * Styled only with `.lantern` + `lt-*` classes driven by `--lt-*` CSS variables
      (no Tailwind utility classes)
    * Icons as heroicons `hero-*` classes (e.g. `<span class="hero-x-mark lt-icon" />`)

  ## Storage-agnostic

  The component never talks to S3 (or any backend). All upload preparation is
  delegated to an adapter implementing `LanternS3.Uploader.Adapter`, injected via
  the `:adapter` / `:adapter_config` assigns. A reference S3 implementation lives
  in `LanternS3.Uploader.S3Adapter`.

  ## Host requirements

    * Lantern stylesheet (`.lantern` root + `lt-*` / `--lt-*`)
    * Heroicons Tailwind plugin for `hero-*` icon classes
    * The JS uploader named in adapter meta (e.g. `"S3"` → `s3_uploader.js`)
      registered on the LiveSocket `uploaders` map

  ## Public assigns

    * `:id` (required)
    * `:adapter` (required) — module implementing `LanternS3.Uploader.Adapter`
    * `:adapter_config` (required) — opaque term passed as arg 1 to `presign/3`
    * `:accept` (default `:any`)
    * `:max_entries` (default `20`)
    * `:max_file_size` (default `50_000_000`)
    * `:hint` (default `nil`) — caption under the dropzone title; when `nil`,
      auto-derived from `:accept` and `:max_file_size`
    * `:on_event` (default `nil`) — optional `fun(event, meta)` called with
      `:completed` / `%{keys: [...]}` when a batch finishes (errors are swallowed)
  """

  use Phoenix.LiveComponent

  require Logger

  alias LanternS3.Errors
  alias LanternUI.Components.Progress

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  def mount(socket) do
    socket =
      socket
      |> assign(:uploads_ready, false)
      |> assign(:completed, [])
      |> assign(:batch_keys, [])
      |> assign(:notice, nil)

    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(:id, assigns.id)
      |> assign(:adapter, assigns.adapter)
      |> assign(:adapter_config, assigns.adapter_config)
      |> assign(:accept, Map.get(assigns, :accept, Map.get(socket.assigns, :accept, :any)))
      |> assign(
        :max_entries,
        Map.get(assigns, :max_entries, Map.get(socket.assigns, :max_entries, 20))
      )
      |> assign(
        :max_file_size,
        Map.get(assigns, :max_file_size, Map.get(socket.assigns, :max_file_size, 50_000_000))
      )
      |> assign(:on_event, Map.get(assigns, :on_event, Map.get(socket.assigns, :on_event)))
      |> assign_hint(assigns)
      |> maybe_allow_upload()

    {:ok, socket}
  end

  defp assign_hint(socket, assigns) do
    case Map.fetch(assigns, :hint) do
      {:ok, nil} ->
        assign(
          socket,
          :hint,
          auto_hint(socket.assigns.accept, socket.assigns.max_file_size)
        )

      {:ok, hint} ->
        assign(socket, :hint, hint)

      :error ->
        case Map.get(socket.assigns, :hint) do
          nil ->
            assign(
              socket,
              :hint,
              auto_hint(socket.assigns.accept, socket.assigns.max_file_size)
            )

          _hint ->
            socket
        end
    end
  end

  # Configure the external upload once. `allow_upload/3` is valid inside a
  # LiveComponent's update/2; the presign function calls the injected adapter.
  defp maybe_allow_upload(socket) do
    if socket.assigns.uploads_ready do
      socket
    else
      socket
      |> allow_upload(:files,
        accept: socket.assigns.accept,
        max_entries: socket.assigns.max_entries,
        max_file_size: socket.assigns.max_file_size,
        auto_upload: true,
        progress: &handle_progress/3,
        external: &presign/2
      )
      |> assign(:uploads_ready, true)
    end
  end

  # External presign: adapter prepares the target; meta is relayed to the JS uploader.
  defp presign(entry, socket) do
    adapter = socket.assigns.adapter
    config = socket.assigns.adapter_config

    case adapter.presign(
           config,
           %{filename: entry.client_name, content_type: entry.client_type},
           []
         ) do
      {:ok, meta} ->
        {:ok, meta, socket}

      {:error, reason} ->
        Logger.warning("LanternS3.Uploader presign failed: #{inspect(reason)}")
        {:error, %{reason: to_string_reason(reason)}, socket}
    end
  end

  # Auto-upload progress: consume each finished entry, persist a completed row,
  # and fire `on_event` once nothing remains in flight for the batch.
  defp handle_progress(:files, entry, socket) do
    if entry.done? do
      key =
        consume_uploaded_entry(socket, entry, fn meta ->
          {:ok, Map.get(meta, :key, entry.client_name)}
        end)

      item = %{key: key, name: entry.client_name, size: entry.client_size}
      completed = socket.assigns.completed ++ [item]
      done = [key | socket.assigns.batch_keys]
      still_uploading? = upload_still_in_flight?(socket.assigns.uploads.files, entry.ref)

      socket =
        if still_uploading? do
          socket
          |> assign(:completed, completed)
          |> assign(:batch_keys, done)
        else
          keys = Enum.reverse(done)
          count = length(keys)

          socket
          |> assign(:completed, completed)
          |> assign(:batch_keys, [])
          |> assign(:notice, upload_success_message(count))
          |> emit(:completed, %{keys: keys})
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # An entry is still "in flight" if it hasn't finished, been cancelled, been
  # marked invalid, or collected a per-entry error (e.g. external PUT failure).
  defp upload_still_in_flight?(conf, except_ref) do
    error_refs = MapSet.new(for {ref, _} <- conf.errors, do: ref)

    Enum.any?(conf.entries, fn e ->
      e.ref != except_ref and
        not e.done? and
        not e.cancelled? and
        e.valid? and
        not MapSet.member?(error_refs, e.ref)
    end)
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :files, ref)}
  end

  def handle_event("clear", %{"key" => key}, socket) do
    completed = Enum.reject(socket.assigns.completed, &(&1.key == key))
    {:noreply, assign(socket, :completed, completed)}
  end

  def handle_event("clear_all", _params, socket) do
    {:noreply, assign(socket, :completed, [])}
  end

  def handle_event("validate_upload", _params, socket) do
    # File selection kicks off auto_upload; clear a prior success notice so the
    # progress rows are the focus for the new batch.
    {:noreply, assign(socket, :notice, nil)}
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="lantern">
      <%= if @notice do %>
        <div class="lt-success lt-banner-body" role="status">
          <span>{@notice}</span>
        </div>
      <% end %>

      <form id={"#{@id}-form"} phx-change="validate_upload" phx-target={@myself}>
        <div class="lt-dropzone-card lt-drop-zone" phx-drop-target={@uploads.files.ref}>
          <div class="lt-dropzone-cloud" aria-hidden="true">
            <span class="hero-cloud-arrow-up lt-icon" />
          </div>
          <p class="lt-dropzone-title">Choose a file or drag &amp; drop it here</p>
          <p class="lt-dropzone-hint">{@hint}</p>
          <label class="lt-dropzone-browse">
            Browse File <.live_file_input upload={@uploads.files} class="sr-only" />
          </label>
        </div>
      </form>

      <ul
        :if={@uploads.files.entries != [] or @completed != []}
        class="lt-uploader-list"
      >
        <li :for={entry <- @uploads.files.entries} class="lt-uploader-row">
          <div class="lt-uploader-file">
            <span class="hero-document lt-icon" />
            <span class="lt-uploader-badge">{file_ext(entry.client_name)}</span>
          </div>
          <div class="lt-uploader-meta">
            <span class="lt-uploader-name">{entry.client_name}</span>
            <span class="lt-uploader-bytes">
              {fmt(round(entry.client_size * entry.progress / 100))} of {fmt(entry.client_size)}
            </span>
            <Progress.progress
              value={entry.progress}
              size="sm"
              shimmer
              label={"Upload progress for #{entry.client_name}"}
            />
            <p
              :for={err <- upload_errors(@uploads.files, entry)}
              class="lt-error"
              style="padding: 0.15rem 0; background: transparent;"
            >
              {upload_error_to_string(err)}
            </p>
          </div>
          <div class="lt-uploader-status lt-uploader-status--uploading">
            <span>Uploading…</span>
          </div>
          <button
            type="button"
            phx-click="cancel_upload"
            phx-value-ref={entry.ref}
            phx-target={@myself}
            class="lt-iconbtn"
            aria-label={"Cancel upload of #{entry.client_name}"}
          >
            <span class="hero-x-mark lt-icon lt-icon-sm" />
          </button>
        </li>

        <li :for={item <- @completed} class="lt-uploader-row">
          <div class="lt-uploader-file">
            <span class="hero-document lt-icon" />
            <span class="lt-uploader-badge">{file_ext(item.name)}</span>
          </div>
          <div class="lt-uploader-meta">
            <span class="lt-uploader-name">{item.name}</span>
            <span class="lt-uploader-bytes">
              {fmt(item.size)} of {fmt(item.size)}
            </span>
          </div>
          <div class="lt-uploader-status lt-uploader-status--done">
            <span class="hero-check-circle lt-icon lt-icon-sm" />
            <span>Completed</span>
          </div>
          <button
            type="button"
            phx-click="clear"
            phx-value-key={item.key}
            phx-target={@myself}
            class="lt-iconbtn"
            aria-label={"Clear #{item.name}"}
          >
            <span class="hero-x-mark lt-icon lt-icon-sm" />
          </button>
        </li>
      </ul>

      <div :if={@completed != []} class="lt-uploader-clearall">
        <button type="button" phx-click="clear_all" phx-target={@myself} class="lt-linkbtn">
          Clear all
        </button>
      </div>

      <p
        :for={err <- if(@uploads_ready, do: upload_errors(@uploads.files), else: [])}
        class="lt-error"
        style="padding: 0.25rem 0; background: transparent;"
      >
        {upload_error_to_string(err)}
      </p>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp emit(socket, event, metadata) do
    case socket.assigns.on_event do
      fun when is_function(fun, 2) ->
        try do
          fun.(event, metadata)
        rescue
          _ -> :ok
        end

        socket

      _ ->
        socket
    end
  end

  defp auto_hint(:any, max_file_size) do
    "JPEG, PNG, PDF, and MP4 formats, up to #{fmt(max_file_size)}."
  end

  defp auto_hint(accept, max_file_size) when is_list(accept) do
    labels =
      accept
      |> Enum.map(&accept_label/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    formats =
      case labels do
        [] ->
          "Supported formats"

        [one] ->
          "#{one} format"

        many ->
          {init, [last]} = Enum.split(many, -1)
          Enum.join(init, ", ") <> ", and " <> last <> " formats"
      end

    "#{formats}, up to #{fmt(max_file_size)}."
  end

  defp auto_hint(_accept, max_file_size), do: "Files up to #{fmt(max_file_size)}."

  defp accept_label("image/*"), do: "Images"
  defp accept_label("video/*"), do: "Video"
  defp accept_label("audio/*"), do: "Audio"
  defp accept_label("application/pdf"), do: "PDF"
  defp accept_label("image/jpeg"), do: "JPEG"
  defp accept_label("image/png"), do: "PNG"
  defp accept_label("image/gif"), do: "GIF"
  defp accept_label("image/webp"), do: "WebP"
  defp accept_label("video/mp4"), do: "MP4"
  defp accept_label("." <> ext), do: String.upcase(ext)

  defp accept_label(type) when is_binary(type) do
    case String.split(type, "/") do
      [_type, subtype] -> String.upcase(subtype)
      _ -> nil
    end
  end

  defp accept_label(_), do: nil

  defp file_ext(name) when is_binary(name) do
    case Path.extname(name) |> String.trim_leading(".") |> String.upcase() do
      "" -> "FILE"
      ext -> ext
    end
  end

  defp file_ext(_), do: "FILE"

  # User-facing byte sizes use decimal units (1000) so defaults like
  # max_file_size: 50_000_000 read as "50 MB" rather than ~47.7 MiB.
  defp fmt(nil), do: "0 B"
  defp fmt(n) when is_integer(n) and n < 0, do: fmt(0)
  defp fmt(n) when is_integer(n) and n < 1000, do: "#{n} B"

  defp fmt(n) when is_integer(n) and n < 1_000_000 do
    kb = n / 1000

    if kb >= 10 do
      "#{round(kb)} KB"
    else
      "#{trim_float(Float.round(kb, 1))} KB"
    end
  end

  defp fmt(n) when is_integer(n) do
    mb = n / 1_000_000

    if mb >= 10 do
      "#{round(mb)} MB"
    else
      "#{trim_float(Float.round(mb, 1))} MB"
    end
  end

  defp fmt(n) when is_float(n), do: fmt(round(n))

  defp trim_float(n) when is_float(n) do
    if n == trunc(n), do: trunc(n), else: n
  end

  defp to_string_reason(reason) when is_binary(reason), do: reason
  defp to_string_reason(reason), do: Errors.humanize(reason)

  defp upload_success_message(1), do: "1 file uploaded"
  defp upload_success_message(n) when is_integer(n) and n > 1, do: "#{n} files uploaded"
  defp upload_success_message(_), do: "Upload complete"

  defp upload_error_to_string(:too_large), do: "File is too large."
  defp upload_error_to_string(:too_many_files), do: "Too many files selected."
  defp upload_error_to_string(:not_accepted), do: "This file type is not accepted."
  defp upload_error_to_string(:external_client_failure), do: "Upload failed. Try again."
  defp upload_error_to_string(err) when is_binary(err), do: err
  defp upload_error_to_string(err), do: Errors.humanize(err)
end
