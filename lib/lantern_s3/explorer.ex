defmodule LanternS3.Explorer do
  @moduledoc """
  A self-contained S3 bucket viewer / file manager as a `Phoenix.LiveComponent`.

  ## OSS-extraction contract

  This module is deliberately portable into a standalone `lantern-s3` hex
  package. To keep it host-agnostic it obeys hard constraints:

    * It `use`s `Phoenix.LiveComponent` directly — never a host `:live_component`
      macro.
    * It contains **no host-app references**, never reads global application
      config, and uses **no host UI-library components**. All controls (buttons,
      the dropdown
      menu, modals) are plain `Phoenix.Component` markup styled with the shared
      Lantern `lt-*` design system — no Tailwind utility classes.
    * Everything it needs is injected via a `%LanternS3.Scope{}` (the `:scope`
      assign): the storage `adapter`, an opaque `config`, the `buckets` it may
      open, a `capabilities` `MapSet`, and an optional `on_event` audit seam.

  ## Host requirements

    * **Lantern stylesheet** — LanternS3 shares the sibling Lantern DB
      explorer's design system. The host app must include the bundled
      `lantern.css` (the `.lantern` root + `lt-*` classes driven by `--lt-*`
      CSS variables); this app already imports it in `assets/css/app.css`. Any
      element rendered with `class="lantern"` + `lt-*` classes is then styled
      automatically and consistently with the DB explorer.
    * **Heroicons Tailwind plugin** — icons are rendered as `hero-*` utility
      classes (e.g. `<span class="hero-folder lt-icon" />`). The host app's
      Tailwind build must include the heroicons plugin for these to appear;
      the `lt-icon`/`lt-icon-sm` classes size them.
    * **JS hooks** — `assets/js/lantern/s3_uploader.js` provides the external
      direct-to-S3 `Uploader` (registered in the LiveSocket `uploaders` map as
      `S3`), and a `LanternS3Download` hook triggers browser downloads from a
      `lantern:download` push event. Both must be wired in the host's `app.js`.

  ## Asynchrony

  Every listing / copy / delete adapter call runs through `start_async/3` so the
  component never blocks the LiveView process; results fold back in via
  `handle_async/3`.
  """

  use Phoenix.LiveComponent

  alias LanternS3.Errors
  alias LanternS3.Scope
  alias LanternS3.Uploader
  alias LanternS3.Uploader.S3Adapter
  alias LanternUI.Components.Breadcrumb
  alias LanternUI.Components.Button
  alias LanternUI.Components.Dropdown
  alias LanternUI.Components.EmptyState
  alias LanternUI.Components.Loading

  @page_size 100

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @impl true
  def mount(socket) do
    socket =
      socket
      |> assign(:current_bucket, nil)
      |> assign(:prefix, "")
      |> assign(:entries, %{folders: [], files: []})
      |> assign(:cursor, nil)
      |> assign(:cursor_stack, [])
      |> assign(:next_token, nil)
      |> assign(:selection, MapSet.new())
      |> assign(:loading, false)
      |> assign(:error, nil)
      |> assign(:notice, nil)
      |> assign(:op_result, nil)
      |> assign(:op_type, nil)
      |> assign(:modal, nil)
      |> assign(:auto_opened, false)
      |> assign(:show_uploader, false)

    {:ok, socket}
  end

  @impl true
  def update(%{uploaded: meta}, socket) do
    {:ok, socket |> emit(:upload, meta) |> list_async()}
  end

  # Host-triggered re-list that deliberately does NOT emit. A host reacting to the
  # `:upload` event (e.g. to run a post-upload sweep) needs a way to refresh the
  # listing afterwards — object stores are only eventually consistent for LIST, so
  # the re-list on `:uploaded` can race ahead of the new object. Routing that
  # through `:uploaded` would re-emit `:upload` straight back into the host and
  # loop, so refreshes get their own non-emitting path.
  def update(%{refresh: true}, socket) do
    {:ok, list_async(socket)}
  end

  def update(%{scope: %Scope{} = scope} = assigns, socket) do
    socket =
      socket
      |> assign(:scope, scope)
      |> assign(:id, assigns.id)
      |> maybe_auto_open(scope)

    {:ok, socket}
  end

  # When the host requests auto-open and the scope grants exactly one bucket,
  # open straight into that bucket's files instead of showing a one-item picker.
  # Auto-opens only on the first pass (guarded on the still-nil current_bucket) so
  # a re-render from the host doesn't yank the operator back to the bucket root.
  # `:auto_opened` is kept true only while sitting on the auto-opened bucket; it is
  # cleared whenever auto-open no longer applies (e.g. the scope grows to 2+
  # buckets, or the operator navigated elsewhere) so the breadcrumb stays
  # clickable and bucket switching is never wedged.
  defp maybe_auto_open(socket, %Scope{} = scope) do
    case {Scope.auto_open_bucket(scope), socket.assigns.current_bucket} do
      {%{name: name}, nil} ->
        socket
        |> assign(:current_bucket, name)
        |> assign(:auto_opened, true)
        |> reset_navigation()
        |> emit(:select_bucket, %{bucket: name})
        |> list_async()

      {%{name: name}, current_bucket} when current_bucket == name ->
        assign(socket, :auto_opened, true)

      _ ->
        assign(socket, :auto_opened, false)
    end
  end

  # ---------------------------------------------------------------------------
  # Navigation events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("select_bucket", %{"bucket" => name}, socket) do
    if allowed_bucket?(socket, name) do
      socket =
        socket
        |> assign(:current_bucket, name)
        |> reset_navigation()
        |> emit(:select_bucket, %{bucket: name})

      {:noreply, list_async(socket)}
    else
      {:noreply, assign(socket, :error, "That bucket is not available.")}
    end
  end

  def handle_event("close_bucket", _params, socket) do
    socket =
      socket
      |> assign(:current_bucket, nil)
      |> reset_navigation()

    {:noreply, socket}
  end

  def handle_event("navigate", %{"prefix" => prefix}, socket) do
    # Navigation guard: never let a client-supplied prefix escape the scope's
    # locked root (multi-tenant isolation). Out-of-bounds targets are ignored.
    if Scope.within_root?(socket.assigns.scope, prefix) do
      socket =
        socket
        |> assign(:prefix, prefix)
        |> reset_paging()
        |> clear_selection_assigns()
        |> emit(:navigate, %{prefix: prefix})

      {:noreply, list_async(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, list_async(socket)}
  end

  def handle_event("next_page", _params, socket) do
    case socket.assigns.next_token do
      nil ->
        {:noreply, socket}

      token ->
        socket =
          socket
          |> update(:cursor_stack, &[socket.assigns.cursor | &1])
          |> assign(:cursor, token)
          |> clear_selection_assigns()

        {:noreply, list_async(socket)}
    end
  end

  def handle_event("prev_page", _params, socket) do
    case socket.assigns.cursor_stack do
      [] ->
        {:noreply, socket}

      [prev | rest] ->
        socket =
          socket
          |> assign(:cursor, prev)
          |> assign(:cursor_stack, rest)
          |> clear_selection_assigns()

        {:noreply, list_async(socket)}
    end
  end

  # ---------------------------------------------------------------------------
  # Selection events
  # ---------------------------------------------------------------------------

  def handle_event("toggle_select", %{"key" => key}, socket) do
    selection =
      if MapSet.member?(socket.assigns.selection, key) do
        MapSet.delete(socket.assigns.selection, key)
      else
        MapSet.put(socket.assigns.selection, key)
      end

    {:noreply, assign(socket, :selection, selection)}
  end

  def handle_event("select_all", _params, socket) do
    all_keys = Enum.map(socket.assigns.entries.files, & &1.key)

    selection =
      if all_selected?(socket) do
        MapSet.new()
      else
        MapSet.new(all_keys)
      end

    {:noreply, assign(socket, :selection, selection)}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, clear_selection_assigns(socket)}
  end

  # ---------------------------------------------------------------------------
  # Download
  # ---------------------------------------------------------------------------

  def handle_event("download", %{"key" => key}, socket) do
    with true <- Scope.can?(socket.assigns.scope, :download),
         %Scope{adapter: adapter, config: config} = socket.assigns.scope,
         {:ok, url} <- adapter.presigned_get(config, socket.assigns.current_bucket, key, []) do
      socket = emit(socket, :download, %{key: key})
      {:noreply, push_event(socket, "lantern:download", %{url: url, name: Path.basename(key)})}
    else
      false ->
        {:noreply, socket}

      {:error, reason} ->
        msg = "Could not prepare download: #{Errors.log_and_humanize("download", reason)}"
        {:noreply, assign(socket, :error, msg)}
    end
  end

  def handle_event("download_selected", _params, socket) do
    if Scope.can?(socket.assigns.scope, :download) do
      %Scope{adapter: adapter, config: config} = socket.assigns.scope
      bucket = socket.assigns.current_bucket
      keys = MapSet.to_list(socket.assigns.selection)

      urls =
        Enum.flat_map(keys, fn key ->
          case adapter.presigned_get(config, bucket, key, []) do
            {:ok, url} -> [%{url: url, name: Path.basename(key)}]
            {:error, _} -> []
          end
        end)

      socket = emit(socket, :download, %{keys: keys})
      {:noreply, push_event(socket, "lantern:download", %{items: urls})}
    else
      {:noreply, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # Modals (open/close)
  # ---------------------------------------------------------------------------

  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, :modal, nil)}
  end

  def handle_event("dismiss_op_result", _params, socket) do
    {:noreply, assign(socket, :op_result, nil)}
  end

  def handle_event("dismiss_error", _params, socket) do
    {:noreply, assign(socket, :error, nil)}
  end

  def handle_event("dismiss_notice", _params, socket) do
    {:noreply, assign(socket, :notice, nil)}
  end

  def handle_event("request_delete", params, socket) do
    keys = delete_target_keys(params, socket)

    if Scope.can?(socket.assigns.scope, :delete) and keys != [] do
      {:noreply, assign(socket, :modal, {:confirm_delete, keys})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("request_create_folder", _params, socket) do
    if Scope.can?(socket.assigns.scope, :create_folder) do
      {:noreply, assign(socket, :modal, :create_folder)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("request_rename", %{"key" => key}, socket) do
    if Scope.can?(socket.assigns.scope, :rename) do
      {:noreply, assign(socket, :modal, {:rename, key})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("request_move", params, socket) do
    keys = move_target_keys(params, socket)

    if Scope.can?(socket.assigns.scope, :move) and keys != [] do
      {:noreply, assign(socket, :modal, {:move, keys})}
    else
      {:noreply, socket}
    end
  end

  # ---------------------------------------------------------------------------
  # Write operations (gated on capabilities)
  # ---------------------------------------------------------------------------

  def handle_event("confirm_delete", %{"keys" => keys}, socket) do
    # `keys[]` form fields arrive as a list; never split on "\n" — an S3 key may
    # legitimately contain newlines, and splitting would corrupt/mis-target it.
    keys = List.wrap(keys)

    if Scope.can?(socket.assigns.scope, :delete) do
      %Scope{adapter: adapter, config: config} = socket.assigns.scope
      bucket = socket.assigns.current_bucket
      {prefixes, files} = Enum.split_with(keys, &String.ends_with?(&1, "/"))

      socket =
        socket
        |> assign(:modal, nil)
        |> assign(:loading, true)
        |> assign(:op_type, :delete)
        |> emit(:delete, %{keys: keys})
        |> start_async(:bulk_op, fn ->
          delete_report =
            if files == [] do
              empty_report()
            else
              files_to_report(adapter.delete_many(config, bucket, files), files)
            end

          Enum.reduce(prefixes, delete_report, fn prefix, acc ->
            merge_reports(acc, adapter.delete_prefix(config, bucket, prefix))
          end)
        end)

      {:noreply, socket}
    else
      {:noreply, assign(socket, :modal, nil)}
    end
  end

  def handle_event("submit_create_folder", %{"name" => name}, socket) do
    name = String.trim(name)

    cond do
      not Scope.can?(socket.assigns.scope, :create_folder) ->
        {:noreply, assign(socket, :modal, nil)}

      name == "" ->
        {:noreply, assign(socket, :error, "Folder name cannot be empty.")}

      true ->
        %Scope{adapter: adapter, config: config} = socket.assigns.scope
        bucket = socket.assigns.current_bucket
        marker = socket.assigns.prefix <> sanitize_segment(name) <> "/"

        socket =
          socket
          |> assign(:modal, nil)
          |> assign(:loading, true)
          |> emit(:create_folder, %{key: marker})
          |> start_async(:mutate, fn ->
            case adapter.put_object(config, bucket, marker, "", []) do
              {:ok, _} -> :ok
              {:error, reason} -> {:error, reason}
            end
          end)

        {:noreply, socket}
    end
  end

  def handle_event("submit_rename", %{"key" => src, "name" => name}, socket) do
    name = String.trim(name)

    cond do
      not Scope.can?(socket.assigns.scope, :rename) ->
        {:noreply, assign(socket, :modal, nil)}

      name == "" ->
        {:noreply, assign(socket, :error, "New name cannot be empty.")}

      true ->
        %Scope{adapter: adapter, config: config} = socket.assigns.scope
        bucket = socket.assigns.current_bucket
        dest = socket.assigns.prefix <> sanitize_segment(name)

        socket =
          socket
          |> assign(:modal, nil)
          |> assign(:loading, true)
          |> assign(:op_type, :rename)
          |> emit(:rename, %{from: src, to: dest})
          |> start_async(:bulk_op, fn -> adapter.move(config, bucket, src, dest) end)

        {:noreply, socket}
    end
  end

  def handle_event("submit_move", %{"keys" => keys, "dest" => dest}, socket) do
    keys = List.wrap(keys)
    dest = dest |> String.trim() |> normalize_dest_prefix()

    if Scope.can?(socket.assigns.scope, :move) do
      %Scope{adapter: adapter, config: config} = socket.assigns.scope
      bucket = socket.assigns.current_bucket

      socket =
        socket
        |> assign(:modal, nil)
        |> assign(:loading, true)
        |> assign(:op_type, :move)
        |> emit(:move, %{keys: keys, dest: dest})
        |> start_async(:bulk_op, fn ->
          Enum.reduce(keys, empty_report(), fn key, acc ->
            report = move_key(adapter, config, bucket, key, dest)
            merge_reports(acc, report)
          end)
        end)

      {:noreply, socket}
    else
      {:noreply, assign(socket, :modal, nil)}
    end
  end

  def handle_event("retry_failed", _params, socket) do
    case socket.assigns.op_result do
      %{failed: failed} when failed != [] ->
        keys = Enum.map(failed, & &1.key)
        {:noreply, retry_modal(socket, keys)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_uploader", _params, socket) do
    {:noreply, assign(socket, :show_uploader, not socket.assigns.show_uploader)}
  end

  # ---------------------------------------------------------------------------
  # Async results
  # ---------------------------------------------------------------------------

  @impl true
  def handle_async(:list, {:ok, {:ok, listing}}, socket) do
    socket =
      socket
      |> assign(:entries, %{folders: listing.folders, files: listing.files})
      |> assign(:next_token, listing.next_token)
      |> assign(:loading, false)
      |> assign(:error, nil)

    {:noreply, socket}
  end

  def handle_async(:list, {:ok, {:error, reason}}, socket) do
    msg = "Failed to list objects: #{Errors.log_and_humanize("list", reason)}"

    socket =
      socket
      |> assign(:loading, false)
      |> assign(:error, msg)

    {:noreply, socket}
  end

  def handle_async(:list, {:exit, reason}, socket) do
    msg = "Listing failed: #{Errors.log_and_humanize("list_exit", reason)}"
    {:noreply, socket |> assign(:loading, false) |> assign(:error, msg)}
  end

  def handle_async(op, {:ok, result}, socket) when op in [:bulk_op, :mutate] do
    socket =
      socket
      |> assign(:loading, false)
      |> clear_selection_assigns()
      |> apply_op_result(result)
      |> list_async()

    {:noreply, socket}
  end

  def handle_async(op, {:exit, reason}, socket) when op in [:bulk_op, :mutate] do
    msg = "Operation failed: #{Errors.log_and_humanize("op_exit", reason)}"

    socket =
      socket
      |> assign(:loading, false)
      |> assign(:error, msg)

    {:noreply, socket}
  end

  # An op_report from a bulk operation drives the partial-failure modal. The
  # adapter wraps single-op reports (rename → `move`) in `{:ok, report}`; the
  # aggregating paths (delete/move) hand back a bare merged report.
  defp apply_op_result(socket, {:ok, %{total: _, succeeded: _, failed: _} = report}) do
    apply_op_result(socket, report)
  end

  defp apply_op_result(socket, %{total: _, succeeded: _, failed: failed} = report) do
    if failed == [] do
      assign(socket, :op_result, nil)
    else
      assign(socket, :op_result, report)
    end
  end

  defp apply_op_result(socket, :ok), do: socket

  defp apply_op_result(socket, {:error, reason}) do
    assign(socket, :error, "Operation failed: #{Errors.log_and_humanize("op", reason)}")
  end

  defp apply_op_result(socket, _other), do: socket

  # ---------------------------------------------------------------------------
  # Async helpers
  # ---------------------------------------------------------------------------

  defp list_async(socket) do
    %Scope{adapter: adapter, config: config} = socket.assigns.scope
    bucket = socket.assigns.current_bucket
    prefix = socket.assigns.prefix
    cursor = socket.assigns.cursor

    if is_nil(bucket) do
      socket
    else
      opts =
        [max_keys: @page_size]
        |> maybe_put(:continuation_token, cursor)

      socket
      |> assign(:loading, true)
      |> assign(:error, nil)
      |> start_async(:list, fn -> adapter.list(config, bucket, prefix, opts) end)
    end
  end

  # Route "Retry failed" back to the modal for the ORIGINAL operation. Only a
  # failed delete may re-open the (destructive) delete-confirm modal; a failed
  # move/rename re-opens the move modal so the user re-picks a destination —
  # never silently turning a non-delete failure into a delete.
  defp retry_modal(socket, keys) do
    case socket.assigns.op_type do
      :delete -> assign(socket, :modal, {:confirm_delete, keys})
      type when type in [:move, :rename] -> assign(socket, :modal, {:move, keys})
      _ -> socket
    end
  end

  defp move_key(adapter, config, bucket, key, dest_prefix) do
    if String.ends_with?(key, "/") do
      base = key |> String.trim_trailing("/") |> Path.basename()
      report = adapter.move_prefix(config, bucket, key, dest_prefix <> base <> "/")
      report
    else
      dest = dest_prefix <> Path.basename(key)
      report = adapter.move(config, bucket, key, dest)
      report
    end
  end

  # ---------------------------------------------------------------------------
  # op_report aggregation
  # ---------------------------------------------------------------------------

  # `succeeded` is an integer COUNT per the `LanternS3.Storage.op_report`
  # contract (never a list of keys).
  defp empty_report, do: %{total: 0, succeeded: 0, failed: []}

  # The adapter's bulk ops return `{:ok, op_report}`; unwrap before merging.
  defp merge_reports(acc, {:ok, %{total: _, succeeded: _, failed: _} = report}) do
    merge_reports(acc, report)
  end

  defp merge_reports(acc, %{total: _, succeeded: _, failed: _} = report) do
    %{
      total: acc.total + report.total,
      succeeded: acc.succeeded + report.succeeded,
      failed: acc.failed ++ report.failed
    }
  end

  defp merge_reports(acc, {:error, reason}) do
    %{acc | failed: acc.failed ++ [%{key: "(operation)", reason: reason}]}
  end

  # delete_many returns {:ok, %{deleted, errors}}; fold it into an op_report.
  defp files_to_report({:ok, %{deleted: deleted, errors: errors}}, attempted) do
    %{
      total: length(attempted),
      succeeded: length(deleted),
      failed: Enum.map(errors, fn e -> %{key: e.key, reason: Map.get(e, :code, :error)} end)
    }
  end

  defp files_to_report({:error, reason}, attempted) do
    %{
      total: length(attempted),
      succeeded: 0,
      failed: Enum.map(attempted, fn key -> %{key: key, reason: reason} end)
    }
  end

  # ---------------------------------------------------------------------------
  # Small state helpers
  # ---------------------------------------------------------------------------

  defp reset_navigation(socket) do
    socket
    |> assign(:prefix, Scope.root_prefix(socket.assigns.scope))
    |> reset_paging()
    |> clear_selection_assigns()
    |> assign(:entries, %{folders: [], files: []})
    |> assign(:error, nil)
  end

  defp reset_paging(socket) do
    socket
    |> assign(:cursor, nil)
    |> assign(:cursor_stack, [])
    |> assign(:next_token, nil)
  end

  defp clear_selection_assigns(socket), do: assign(socket, :selection, MapSet.new())

  defp all_selected?(socket) do
    files = socket.assigns.entries.files
    files != [] and Enum.all?(files, &MapSet.member?(socket.assigns.selection, &1.key))
  end

  defp allowed_bucket?(socket, name) do
    Enum.any?(socket.assigns.scope.buckets, &(&1.name == name))
  end

  defp delete_target_keys(%{"key" => key}, _socket), do: [key]

  defp delete_target_keys(_params, socket),
    do: MapSet.to_list(socket.assigns.selection)

  defp move_target_keys(%{"key" => key}, _socket), do: [key]

  defp move_target_keys(_params, socket),
    do: MapSet.to_list(socket.assigns.selection)

  defp normalize_dest_prefix(""), do: ""

  defp normalize_dest_prefix(dest) do
    if String.ends_with?(dest, "/"), do: dest, else: dest <> "/"
  end

  # Strip slashes from a user-entered folder/file segment so it can't escape
  # the current prefix.
  defp sanitize_segment(name) do
    name
    |> String.replace("/", "")
    |> String.trim()
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # Call the host audit/telemetry seam, if provided. Never lets a host error
  # disrupt the component.
  defp emit(socket, event, metadata) do
    case socket.assigns.scope.on_event do
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

  # Bridge the child Uploader's completion back to the Explorer: re-list the
  # current folder and forward the host audit event.
  defp uploader_on_event(id) do
    fn :completed, meta -> send_update(__MODULE__, id: id, uploaded: meta) end
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="lantern" phx-hook="LanternS3Download">
      <%= if @error do %>
        <div class="lt-error lt-banner-body" role="alert">
          <span>{@error}</span>
          <button
            type="button"
            class="lt-iconbtn"
            phx-click="dismiss_error"
            phx-target={@myself}
            aria-label="Dismiss error"
          >
            <span class="hero-x-mark lt-icon" />
          </button>
        </div>
      <% end %>

      <%= if @notice do %>
        <div class="lt-success lt-banner-body" role="status">
          <span>{@notice}</span>
          <button
            type="button"
            class="lt-iconbtn"
            phx-click="dismiss_notice"
            phx-target={@myself}
            aria-label="Dismiss notice"
          >
            <span class="hero-x-mark lt-icon" />
          </button>
        </div>
      <% end %>

      <%= if is_nil(@current_bucket) do %>
        {bucket_picker(assigns)}
      <% else %>
        {browser(assigns)}
      <% end %>

      {modals(assigns)}
      {op_result_modal(assigns)}
    </div>
    """
  end

  # --- bucket picker ---------------------------------------------------------

  defp bucket_picker(assigns) do
    ~H"""
    <div class="lt-body">
      <div class="lt-content">
        <header class="lt-topbar">
          <div class="lt-topbar-group">
            <div class="lt-identity">
              <span class="hero-archive-box lt-icon lt-identity-icon" />
              <span class="lt-crumb-table">Buckets</span>
            </div>
          </div>
        </header>
        <%= if @scope.buckets == [] do %>
          <div class="lt-empty">
            <span class="hero-archive-box lt-icon-lg" />
            <p class="lt-note">No buckets available.</p>
          </div>
        <% else %>
          <nav class="lt-table-list">
            <button
              :for={bucket <- @scope.buckets}
              type="button"
              phx-click="select_bucket"
              phx-value-bucket={bucket.name}
              phx-target={@myself}
              class="lt-table-item"
            >
              <span class="lt-field">
                <span class="hero-archive-box lt-icon lt-identity-icon" />
                <span class="lt-table-name">{bucket.label}</span>
              </span>
            </button>
          </nav>
        <% end %>
      </div>
    </div>
    """
  end

  # --- browser (breadcrumb + toolbar + table + pagination) -------------------

  defp browser(assigns) do
    empty? =
      not assigns.loading and assigns.entries.folders == [] and assigns.entries.files == []

    can_page? = assigns.next_token != nil or assigns.cursor_stack != []

    assigns =
      assigns
      |> assign(:selection_count, MapSet.size(assigns.selection))
      |> assign(:empty?, empty?)
      |> assign(:can_page?, can_page?)

    ~H"""
    <div class="lt-body">
      <div class="lt-content">
        {breadcrumb(assigns)}

        <div class="lt-main">
          {toolbar(assigns)}

          <%= if @selection_count > 0 do %>
            {selection_toolbar(assigns)}
          <% end %>

          <div
            :if={@show_uploader and Scope.can?(@scope, :upload) and @current_bucket}
            class="lt-uploader-panel"
          >
            <.live_component
              module={Uploader}
              id={"#{@id}-uploader"}
              adapter={@scope.upload_adapter || S3Adapter}
              adapter_config={
                %{
                  storage_adapter: @scope.adapter,
                  storage_config: @scope.config,
                  bucket: @current_bucket,
                  prefix: @prefix
                }
              }
              accept={Map.get(@scope.upload_opts, :accept, :any)}
              max_entries={Map.get(@scope.upload_opts, :max_entries, 20)}
              max_file_size={Map.get(@scope.upload_opts, :max_file_size, 50_000_000)}
              on_event={uploader_on_event(@id)}
            />
          </div>

          <%= if @empty? do %>
            {empty_folder(assigns)}
          <% else %>
            <div class="lt-grid">
              <table class="lt-table">
                <thead>
                  <tr>
                    <th scope="col" class="lt-check">
                      <input
                        type="checkbox"
                        class="lui-checkbox"
                        phx-click="select_all"
                        phx-target={@myself}
                        checked={@selection_count > 0 and @selection_count == length(@entries.files)}
                      />
                    </th>
                    <th scope="col" class="lt-th">Name</th>
                    <th scope="col" class="lt-th lt-th-num">Size</th>
                    <th scope="col" class="lt-th">Modified</th>
                    <th scope="col" class="lt-th lt-th-actions"></th>
                  </tr>
                </thead>
                <tbody>
                  <%= if @loading do %>
                    <tr>
                      <td colspan="5" class="lt-empty-row">
                        <span class="lt-field" style="justify-content: center;">
                          <Loading.loading size="sm" label="Loading" />
                          <span class="lt-note">Loading…</span>
                        </span>
                      </td>
                    </tr>
                  <% else %>
                    <tr :for={folder <- @entries.folders} class="lt-row">
                      <td class="lt-check"></td>
                      <td class="lt-td">
                        <button
                          type="button"
                          phx-click="navigate"
                          phx-value-prefix={folder.prefix}
                          phx-target={@myself}
                          class="lt-fk-link lt-field"
                        >
                          <span class="hero-folder lt-icon" />
                          {folder.name}
                        </button>
                      </td>
                      <td class="lt-td lt-cell-number lt-null-text">—</td>
                      <td class="lt-td lt-null-text">—</td>
                      <td class="lt-td-actions">
                        {row_menu(assign(assigns, :entry, %{key: folder.prefix, kind: :folder}))}
                      </td>
                    </tr>

                    <tr :for={file <- @entries.files} class="lt-row">
                      <td class="lt-check">
                        <input
                          type="checkbox"
                          class="lui-checkbox"
                          phx-click="toggle_select"
                          phx-value-key={file.key}
                          phx-target={@myself}
                          checked={MapSet.member?(@selection, file.key)}
                        />
                      </td>
                      <td class="lt-td">
                        <span class="lt-field">
                          <span class="hero-document lt-icon" />
                          {file.name}
                        </span>
                      </td>
                      <td class="lt-td lt-cell-number">{human_size(file.size)}</td>
                      <td class="lt-td">
                        <time
                          datetime={modified_absolute(file.last_modified)}
                          title={modified_absolute(file.last_modified)}
                        >
                          {modified_relative(file.last_modified)}
                        </time>
                      </td>
                      <td class="lt-td-actions">
                        {row_menu(assign(assigns, :entry, %{key: file.key, kind: :file}))}
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>

            <%= if @can_page? do %>
              {pagination(assigns)}
            <% end %>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp empty_folder(assigns) do
    ~H"""
    <div class="lt-empty-bleed">
      <%= if Scope.can?(@scope, :upload) do %>
        <EmptyState.empty_state icon="folder-open" title="This folder is empty">
          Upload files to this folder
          <:action>
            <Button.button size="sm" phx-click="toggle_uploader" phx-target={@myself}>
              <span class="hero-arrow-up-tray lt-icon" /> Upload
            </Button.button>
          </:action>
        </EmptyState.empty_state>
      <% else %>
        <EmptyState.empty_state icon="folder-open" title="This folder is empty" />
      <% end %>
    </div>
    """
  end

  defp breadcrumb(assigns) do
    root_prefix = Scope.root_prefix(assigns.scope)
    segments = breadcrumb_segments(assigns.prefix, root_prefix)

    assigns =
      assigns
      |> assign(:segments, segments)
      |> assign(:root_prefix, root_prefix)
      |> assign(:bucket_label, bucket_label(assigns.scope, assigns.current_bucket))
      |> assign(:at_root?, segments == [])

    ~H"""
    <header class="lt-topbar">
      <div class="lt-topbar-group">
        <div class="lt-identity">
          <span class="hero-archive-box lt-icon lt-identity-icon" />
          <Breadcrumb.breadcrumb aria_label="Object path">
            <:item :if={@auto_opened and @at_root?} current>{@bucket_label}</:item>
            <:item
              :if={@auto_opened and not @at_root?}
              phx-click="navigate"
              phx-value-prefix={@root_prefix}
              phx-target={@myself}
            >
              {@bucket_label}
            </:item>
            <:item :if={!@auto_opened} phx-click="close_bucket" phx-target={@myself}>
              {@bucket_label}
            </:item>
            <:item
              :for={segment <- @segments}
              phx-click="navigate"
              phx-value-prefix={segment.prefix}
              phx-target={@myself}
            >
              {segment.label}
            </:item>
          </Breadcrumb.breadcrumb>
        </div>
      </div>
    </header>
    """
  end

  defp toolbar(assigns) do
    ~H"""
    <div class="lt-toolbar">
      <div class="lt-actions">
        <Button.button
          :if={Scope.can?(@scope, :upload)}
          size="sm"
          phx-click="toggle_uploader"
          phx-target={@myself}
        >
          <span class="hero-arrow-up-tray lt-icon" /> Upload
        </Button.button>
        <%= if Scope.can?(@scope, :create_folder) do %>
          <Button.button size="sm" phx-click="request_create_folder" phx-target={@myself}>
            <span class="hero-folder-plus lt-icon" /> New folder
          </Button.button>
        <% end %>
        <Button.button
          size="sm"
          variant="ghost"
          phx-click="refresh"
          phx-target={@myself}
          aria-label="Refresh"
        >
          <span class="hero-arrow-path lt-icon" />
        </Button.button>
      </div>
    </div>
    """
  end

  defp selection_toolbar(assigns) do
    ~H"""
    <div class="lt-toolbar">
      <span class="lt-note">
        {@selection_count} selected
      </span>
      <div class="lt-actions">
        <%= if Scope.can?(@scope, :download) do %>
          <Button.button size="sm" phx-click="download_selected" phx-target={@myself}>
            <span class="hero-arrow-down-tray lt-icon" /> Download
          </Button.button>
        <% end %>
        <%= if Scope.can?(@scope, :move) do %>
          <Button.button size="sm" phx-click="request_move" phx-target={@myself}>
            <span class="hero-arrows-right-left lt-icon" /> Move
          </Button.button>
        <% end %>
        <%= if Scope.can?(@scope, :delete) do %>
          <Button.button
            size="sm"
            variant="solid"
            color="danger"
            phx-click="request_delete"
            phx-target={@myself}
          >
            <span class="hero-trash lt-icon" /> Delete
          </Button.button>
        <% end %>
        <Button.button size="sm" variant="ghost" phx-click="clear_selection" phx-target={@myself}>
          Clear
        </Button.button>
      </div>
    </div>
    """
  end

  defp pagination(assigns) do
    ~H"""
    <div class="lt-footer">
      <span></span>
      <div class="lt-pager">
        <Button.button
          size="sm"
          phx-click="prev_page"
          phx-target={@myself}
          disabled={@cursor_stack == []}
        >
          <span class="hero-chevron-left lt-icon lt-icon-sm" /> Prev
        </Button.button>
        <Button.button
          size="sm"
          phx-click="next_page"
          phx-target={@myself}
          disabled={is_nil(@next_token)}
        >
          Next <span class="hero-chevron-right lt-icon lt-icon-sm" />
        </Button.button>
      </div>
    </div>
    """
  end

  # --- per-row dropdown menu (plain markup, CSS-only open via <details>) ------

  defp row_menu(assigns) do
    assigns =
      assign(assigns, :menu_id, "s3menu-" <> Base.url_encode64(assigns.entry.key, padding: false))

    ~H"""
    <Dropdown.dropdown id={@menu_id} placement="bottom-end">
      <:toggle>
        <Button.button size="icon" variant="ghost" aria-label="Actions">
          <span class="hero-ellipsis-vertical lt-icon" />
        </Button.button>
      </:toggle>
      <%= if @entry.kind == :file and Scope.can?(@scope, :download) do %>
        <Dropdown.dropdown_button phx-click="download" phx-value-key={@entry.key} phx-target={@myself}>
          <span class="hero-arrow-down-tray lt-icon" /> Download
        </Dropdown.dropdown_button>
      <% end %>
      <%= if @entry.kind == :file and Scope.can?(@scope, :rename) do %>
        <Dropdown.dropdown_button
          phx-click="request_rename"
          phx-value-key={@entry.key}
          phx-target={@myself}
        >
          <span class="hero-pencil-square lt-icon" /> Rename
        </Dropdown.dropdown_button>
      <% end %>
      <%= if Scope.can?(@scope, :move) do %>
        <Dropdown.dropdown_button
          phx-click="request_move"
          phx-value-key={@entry.key}
          phx-target={@myself}
        >
          <span class="hero-arrows-right-left lt-icon" /> Move
        </Dropdown.dropdown_button>
      <% end %>
      <%= if Scope.can?(@scope, :delete) do %>
        <Dropdown.dropdown_separator />
        <Dropdown.dropdown_button
          data-danger
          phx-click="request_delete"
          phx-value-key={@entry.key}
          phx-target={@myself}
        >
          <span class="hero-trash lt-icon" /> Delete
        </Dropdown.dropdown_button>
      <% end %>
    </Dropdown.dropdown>
    """
  end

  # --- modals ----------------------------------------------------------------
  # Each modal is rendered inline (no closure-render) so HEEx change-tracking
  # stays sound. `modal_shell/1` is a function component with an :inner slot.

  defp modals(assigns) do
    ~H"""
    <%= case @modal do %>
      <% {:confirm_delete, keys} -> %>
        {confirm_delete_modal(
          assigns
          |> assign(:keys, keys)
          |> assign(:recursive?, Enum.any?(keys, &String.ends_with?(&1, "/")))
        )}
      <% :create_folder -> %>
        {create_folder_modal(assigns)}
      <% {:rename, key} -> %>
        {rename_modal(assign(assigns, :rename_key, key))}
      <% {:move, keys} -> %>
        {move_modal(assign(assigns, :keys, keys))}
      <% _ -> %>
    <% end %>
    """
  end

  defp confirm_delete_modal(assigns) do
    ~H"""
    <.modal_shell myself={@myself}>
      <div class="lt-modal-head">
        <h3 class="lt-modal-title">Delete</h3>
        <button
          type="button"
          class="lt-iconbtn"
          phx-click="close_modal"
          phx-target={@myself}
          aria-label="Close"
        >
          <span class="hero-x-mark lt-icon" />
        </button>
      </div>
      <form phx-submit="confirm_delete" phx-target={@myself}>
        <div class="lt-modal-body">
          <p class="lt-note">
            Delete {length(@keys)} item(s)? This cannot be undone.
          </p>
          <p :if={@recursive?} class="lt-error">
            This includes folders and is recursive and non-atomic — some objects may be
            deleted even if others fail.
          </p>
          <input :for={key <- @keys} type="hidden" name="keys[]" value={key} />
        </div>
        <div class="lt-modal-foot">
          <Button.button type="button" phx-click="close_modal" phx-target={@myself}>
            Cancel
          </Button.button>
          <Button.button type="submit" variant="solid" color="danger">Delete</Button.button>
        </div>
      </form>
    </.modal_shell>
    """
  end

  defp create_folder_modal(assigns) do
    ~H"""
    <.modal_shell myself={@myself}>
      <div class="lt-modal-head">
        <h3 class="lt-modal-title">New folder</h3>
        <button
          type="button"
          class="lt-iconbtn"
          phx-click="close_modal"
          phx-target={@myself}
          aria-label="Close"
        >
          <span class="hero-x-mark lt-icon" />
        </button>
      </div>
      <form phx-submit="submit_create_folder" phx-target={@myself}>
        <div class="lt-modal-body">
          <label class="lt-form-label">
            Folder name
            <input
              type="text"
              name="name"
              autocomplete="off"
              placeholder="folder-name"
              class="lt-input"
            />
          </label>
        </div>
        <div class="lt-modal-foot">
          <Button.button type="button" phx-click="close_modal" phx-target={@myself}>
            Cancel
          </Button.button>
          <Button.button type="submit" variant="solid" color="primary">Create</Button.button>
        </div>
      </form>
    </.modal_shell>
    """
  end

  defp rename_modal(assigns) do
    ~H"""
    <.modal_shell myself={@myself}>
      <div class="lt-modal-head">
        <h3 class="lt-modal-title">Rename</h3>
        <button
          type="button"
          class="lt-iconbtn"
          phx-click="close_modal"
          phx-target={@myself}
          aria-label="Close"
        >
          <span class="hero-x-mark lt-icon" />
        </button>
      </div>
      <form phx-submit="submit_rename" phx-target={@myself}>
        <div class="lt-modal-body">
          <input type="hidden" name="key" value={@rename_key} />
          <label class="lt-form-label">
            New name
            <input
              type="text"
              name="name"
              autocomplete="off"
              value={Path.basename(@rename_key)}
              class="lt-input"
            />
          </label>
        </div>
        <div class="lt-modal-foot">
          <Button.button type="button" phx-click="close_modal" phx-target={@myself}>
            Cancel
          </Button.button>
          <Button.button type="submit" variant="solid" color="primary">Rename</Button.button>
        </div>
      </form>
    </.modal_shell>
    """
  end

  defp move_modal(assigns) do
    ~H"""
    <.modal_shell myself={@myself}>
      <div class="lt-modal-head">
        <h3 class="lt-modal-title">Move</h3>
        <button
          type="button"
          class="lt-iconbtn"
          phx-click="close_modal"
          phx-target={@myself}
          aria-label="Close"
        >
          <span class="hero-x-mark lt-icon" />
        </button>
      </div>
      <form phx-submit="submit_move" phx-target={@myself}>
        <div class="lt-modal-body">
          <p class="lt-note">
            Move {length(@keys)} item(s) to a destination prefix. Recursive moves are
            non-atomic.
          </p>
          <input :for={key <- @keys} type="hidden" name="keys[]" value={key} />
          <label class="lt-form-label">
            Destination prefix
            <input
              type="text"
              name="dest"
              autocomplete="off"
              placeholder="destination/prefix/"
              class="lt-input"
            />
          </label>
        </div>
        <div class="lt-modal-foot">
          <Button.button type="button" phx-click="close_modal" phx-target={@myself}>
            Cancel
          </Button.button>
          <Button.button type="submit" variant="solid" color="primary">Move</Button.button>
        </div>
      </form>
    </.modal_shell>
    """
  end

  defp op_result_modal(assigns) do
    ~H"""
    <%= if @op_result do %>
      <.modal_shell myself={@myself}>
        <div class="lt-modal-head">
          <h3 class="lt-modal-title">Completed with errors</h3>
          <button
            type="button"
            class="lt-iconbtn"
            phx-click="dismiss_op_result"
            phx-target={@myself}
            aria-label="Close"
          >
            <span class="hero-x-mark lt-icon" />
          </button>
        </div>
        <div class="lt-modal-body">
          <p class="lt-note">
            {@op_result.succeeded} of {@op_result.total} succeeded; {length(@op_result.failed)} failed.
          </p>
          <ul class="lt-info-list">
            <li :for={failure <- @op_result.failed} class="lt-info-row">
              <span class="lt-table-name">{failure.key}</span>
              <span class="lt-pill">{Errors.humanize(failure.reason)}</span>
            </li>
          </ul>
        </div>
        <div class="lt-modal-foot">
          <Button.button type="button" phx-click="dismiss_op_result" phx-target={@myself}>
            Close
          </Button.button>
          <Button.button
            type="button"
            variant="solid"
            color="primary"
            phx-click="retry_failed"
            phx-target={@myself}
          >
            Retry failed
          </Button.button>
        </div>
      </.modal_shell>
    <% end %>
    """
  end

  # A bare modal shell (overlay + card) function component with an :inner_block
  # slot, so each modal supplies its own body without a render closure.
  attr(:myself, :any, required: true)
  slot(:inner_block, required: true)

  defp modal_shell(assigns) do
    ~H"""
    <div class="lantern lt-dialog-portal">
      <div class="lui-modal">
        <button
          type="button"
          class="lui-modal-backdrop"
          phx-click="close_modal"
          phx-target={@myself}
          aria-label="Close dialog"
        />
        <div class="lui-modal-panel" role="dialog" aria-modal="true">
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Presentation helpers
  # ---------------------------------------------------------------------------

  # The human-facing label for the open bucket. Falls back to the raw name when
  # the scope has no matching entry (it always should), so the breadcrumb never
  # leaks a hidden backing name when the host supplies a friendly label.
  defp bucket_label(%Scope{buckets: buckets}, name) do
    case Enum.find(buckets, &(&1.name == name)) do
      %{label: label} -> label
      _ -> name
    end
  end

  # Only the path *below* the locked root becomes crumbs; each crumb target is a
  # full key built back up from the root, so navigation stays inside the scope.
  defp breadcrumb_segments(prefix, root_prefix) do
    # String.trim_leading/2 rejects an empty match, so skip it for the ""-root case.
    relative =
      case root_prefix do
        "" -> prefix
        root -> String.trim_leading(prefix, root)
      end

    relative
    |> String.split("/", trim: true)
    |> Enum.reduce({[], root_prefix}, fn segment, {acc, running} ->
      next = running <> segment <> "/"
      {[%{label: segment, prefix: next} | acc], next}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp human_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 2)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 2)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
      true -> "#{bytes} B"
    end
  end

  defp human_size(_), do: "—"

  # Relative "Modified" cell; absolute ISO stays on title/datetime attributes.
  defp modified_relative(value) do
    case parse_modified(value) do
      {:ok, dt} -> relative_time(dt)
      :error -> blank_modified(value)
    end
  end

  defp modified_absolute(value) do
    case parse_modified(value) do
      {:ok, dt} -> DateTime.to_iso8601(dt)
      :error -> blank_modified(value)
    end
  end

  defp blank_modified(value) when value in [nil, ""], do: "—"
  defp blank_modified(value) when is_binary(value), do: value
  defp blank_modified(_), do: "—"

  defp parse_modified(%DateTime{} = dt), do: {:ok, dt}

  defp parse_modified(%NaiveDateTime{} = ndt),
    do: {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}

  defp parse_modified(iso) when is_binary(iso) and iso != "" do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} ->
        {:ok, dt}

      {:error, _} ->
        case NaiveDateTime.from_iso8601(iso) do
          {:ok, ndt} -> {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
          {:error, _} -> :error
        end
    end
  end

  defp parse_modified(_), do: :error

  defp relative_time(%DateTime{} = dt) do
    secs = max(DateTime.diff(DateTime.utc_now(), dt, :second), 0)

    cond do
      secs < 60 -> "#{secs}s ago"
      secs < 3600 -> "#{div(secs, 60)}m ago"
      secs < 86_400 -> "#{div(secs, 3600)}h ago"
      secs < 2_592_000 -> "#{div(secs, 86_400)}d ago"
      true -> Calendar.strftime(dt, "%Y-%m-%d")
    end
  end
end
