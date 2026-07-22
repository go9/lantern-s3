defmodule LanternS3.ExplorerTest do
  use LanternS3.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias LanternS3.Scope

  # A stub LanternS3.Storage adapter. All behaviour state is carried in the opaque
  # `config` (captured into the start_async closures, so it's process-safe), not
  # in the process dictionary.
  defmodule StubAdapter do
    @behaviour LanternS3.Storage

    @impl true
    def list_buckets(config), do: {:ok, Map.get(config, :buckets, [])}

    @impl true
    def list(config, bucket, prefix, _opts) do
      {:ok, Map.get(config.listings, {bucket, prefix}, empty())}
    end

    @impl true
    def presigned_get(_config, _bucket, _key, _opts), do: {:ok, "https://example.test/get"}

    @impl true
    def presigned_put(_config, _bucket, _key, _opts), do: {:ok, "https://example.test/put"}

    @impl true
    def put_object(_config, _bucket, _key, _body, _opts), do: {:ok, %{}}

    @impl true
    def head(_config, _bucket, _key), do: {:ok, %{size: 0, content_type: nil, last_modified: nil}}

    @impl true
    def copy(_config, _bucket, _src, _dest), do: {:ok, %{}}

    @impl true
    def delete_many(config, _bucket, keys) do
      Map.get(config, :delete_many, {:ok, %{deleted: keys, errors: []}})
    end

    @impl true
    def move(_config, _bucket, _src, _dest), do: {:ok, %{total: 1, succeeded: 1, failed: []}}

    @impl true
    def move_prefix(config, _bucket, _src, _dest),
      do: Map.get(config, :move_prefix, {:ok, %{total: 0, succeeded: 0, failed: []}})

    @impl true
    def delete_prefix(config, _bucket, _prefix) do
      Map.get(config, :delete_prefix, {:ok, %{total: 0, succeeded: 0, failed: []}})
    end

    defp empty, do: %{folders: [], files: [], next_token: nil, truncated?: false}
  end

  # A minimal host LiveView that mounts the component with a Scope built from
  # session data — mirrors what a real Flicker mount does.
  defmodule HostLive do
    use Phoenix.LiveView

    def mount(_params, session, socket) do
      scope =
        Scope.new(
          adapter: StubAdapter,
          config: session["config"],
          buckets: session["buckets"],
          capabilities: session["capabilities"],
          auto_open: session["auto_open"]
        )

      {:ok, Phoenix.Component.assign(socket, :scope, scope)}
    end

    def render(assigns) do
      ~H"""
      <.live_component module={LanternS3.Explorer} id="lantern-test" scope={@scope} />
      """
    end
  end

  defp config_with(listings, extra \\ %{}) do
    Map.merge(%{listings: listings}, extra)
  end

  defp boot(conn, opts) do
    session = %{
      "config" => Keyword.fetch!(opts, :config),
      "buckets" => Keyword.get(opts, :buckets, [%{name: "media", label: "media"}]),
      "capabilities" => Keyword.get(opts, :capabilities, :all),
      "auto_open" => Keyword.get(opts, :auto_open, false)
    }

    live_isolated(conn, HostLive, session: session)
  end

  describe "bucket picker" do
    test "lists the buckets the scope grants", %{conn: conn} do
      {:ok, view, _html} =
        boot(conn,
          config: config_with(%{}),
          buckets: [%{name: "media", label: "Media"}, %{name: "logs", label: "Logs"}]
        )

      html = render(view)
      assert html =~ "Media"
      assert html =~ "Logs"
    end

    test "shows an empty state when no buckets are granted", %{conn: conn} do
      {:ok, view, _html} = boot(conn, config: config_with(%{}), buckets: [])
      assert render(view) =~ "No buckets available."
    end
  end

  describe "navigation" do
    test "selecting a bucket lists its folders and files", %{conn: conn} do
      listings = %{
        {"media", ""} => %{
          folders: [%{prefix: "images/", name: "images"}],
          files: [
            %{key: "readme.txt", name: "readme.txt", size: 12, last_modified: nil, etag: "e"}
          ],
          next_token: nil,
          truncated?: false
        }
      }

      {:ok, view, _html} = boot(conn, config: config_with(listings))

      view |> element(~s(button[phx-value-bucket="media"])) |> render_click()
      html = render_async(view)

      assert html =~ "images"
      assert html =~ "readme.txt"
    end

    test "navigating into a folder re-lists at the new prefix", %{conn: conn} do
      listings = %{
        {"media", ""} => %{
          folders: [%{prefix: "images/", name: "images"}],
          files: [],
          next_token: nil,
          truncated?: false
        },
        {"media", "images/"} => %{
          folders: [],
          files: [
            %{key: "images/cat.png", name: "cat.png", size: 99, last_modified: nil, etag: "c"}
          ],
          next_token: nil,
          truncated?: false
        }
      }

      {:ok, view, _html} = boot(conn, config: config_with(listings))

      view |> element(~s(button[phx-value-bucket="media"])) |> render_click()
      render_async(view)

      view |> element(~s([phx-click="navigate"][phx-value-prefix="images/"])) |> render_click()
      html = render_async(view)

      assert html =~ "cat.png"
    end
  end

  describe "auto-open" do
    test "a single granted bucket with auto_open opens straight into its files",
         %{conn: conn} do
      listings = %{
        {"media", ""} => %{
          folders: [%{prefix: "images/", name: "images"}],
          files: [],
          next_token: nil,
          truncated?: false
        }
      }

      {:ok, view, _html} =
        boot(conn,
          config: config_with(listings),
          buckets: [%{name: "media", label: "media"}],
          auto_open: true
        )

      html = render_async(view)

      # We skipped the picker and landed inside the bucket.
      assert html =~ "images"
      # The top crumb collapses to a non-clickable label (auto_opened == true),
      # so there is no close_bucket button for the lone bucket.
      assert html =~ ~s(aria-current="page")
      refute html =~ ~s(phx-click="close_bucket")
    end

    test "two granted buckets with auto_open still show a clickable picker",
         %{conn: conn} do
      # Regression for the stale-:auto_opened bug: when the scope grants 2+
      # buckets, auto-open must not apply and must not wedge the breadcrumb into
      # the non-clickable collapsed state.
      {:ok, view, _html} =
        boot(conn,
          config: config_with(%{}),
          buckets: [%{name: "media", label: "Media"}, %{name: "logs", label: "Logs"}],
          auto_open: true
        )

      html = render(view)

      # Picker is shown, not auto-opened.
      assert html =~ "Media"
      assert html =~ "Logs"
      assert html =~ ~s(phx-value-bucket="media")
    end

    test "after auto-open the operator can still navigate within the bucket",
         %{conn: conn} do
      listings = %{
        {"media", ""} => %{
          folders: [%{prefix: "images/", name: "images"}],
          files: [],
          next_token: nil,
          truncated?: false
        },
        {"media", "images/"} => %{
          folders: [],
          files: [
            %{key: "images/cat.png", name: "cat.png", size: 99, last_modified: nil, etag: "c"}
          ],
          next_token: nil,
          truncated?: false
        }
      }

      {:ok, view, _html} =
        boot(conn,
          config: config_with(listings),
          buckets: [%{name: "media", label: "media"}],
          auto_open: true
        )

      render_async(view)

      # Auto-open must not wedge navigation: drilling into a folder still re-lists.
      view |> element(~s([phx-click="navigate"][phx-value-prefix="images/"])) |> render_click()
      html = render_async(view)

      assert html =~ "cat.png"
    end
  end

  describe "capability gating" do
    test "hides the upload control when :upload is not granted", %{conn: conn} do
      listings = %{
        {"media", ""} => %{folders: [], files: [], next_token: nil, truncated?: false}
      }

      caps = MapSet.new([:download])
      {:ok, view, _html} = boot(conn, config: config_with(listings), capabilities: caps)

      view |> element(~s(button[phx-value-bucket="media"])) |> render_click()
      html = render_async(view)

      refute html =~ "toggle_uploader"
      refute has_element?(view, ~s(button[phx-click="toggle_uploader"]))
    end
  end

  describe "uploader panel" do
    test "toolbar Upload toggles the embedded Uploader component", %{conn: conn} do
      listings = %{
        {"media", ""} => %{
          folders: [],
          files: [%{key: "a.txt", name: "a.txt", size: 1, last_modified: nil}],
          next_token: nil,
          truncated?: false
        }
      }

      {:ok, view, _html} = boot(conn, config: config_with(listings))

      view |> element(~s(button[phx-value-bucket="media"])) |> render_click()
      html = render_async(view)

      assert has_element?(view, ~s(button[phx-click="toggle_uploader"]))
      refute html =~ "lantern-test-uploader"
      refute has_element?(view, "#lantern-test-uploader")

      view |> element(~s(button[phx-click="toggle_uploader"])) |> render_click()
      html = render(view)

      assert has_element?(view, "#lantern-test-uploader")
      assert html =~ "lt-uploader-panel"

      view |> element(~s(button[phx-click="toggle_uploader"])) |> render_click()
      refute has_element?(view, "#lantern-test-uploader")
    end
  end

  describe "bulk delete + partial-failure modal" do
    test "a folder delete that partially fails surfaces the op_result modal", %{conn: conn} do
      listings = %{
        {"media", ""} => %{
          folders: [%{prefix: "junk/", name: "junk"}],
          files: [],
          next_token: nil,
          truncated?: false
        }
      }

      delete_prefix_report =
        {:ok,
         %{
           total: 2,
           succeeded: 1,
           failed: [%{key: "junk/b", reason: :access_denied}]
         }}

      config = config_with(listings, %{delete_prefix: delete_prefix_report})
      {:ok, view, _html} = boot(conn, config: config)

      view |> element(~s(button[phx-value-bucket="media"])) |> render_click()
      render_async(view)

      # delete the folder via its row menu, then confirm in the modal form
      view |> element(~s([phx-click="request_delete"][phx-value-key="junk/"])) |> render_click()
      view |> form(~s(form[phx-submit="confirm_delete"])) |> render_submit()
      html = render_async(view)

      assert html =~ "Completed with errors"
      assert html =~ "junk/b"
      assert html =~ "1 of 2 succeeded"
    end
  end

  describe "retry routing for non-delete operations" do
    test "retrying a failed move re-opens the move modal, not delete", %{conn: conn} do
      listings = %{
        {"media", ""} => %{
          folders: [%{prefix: "junk/", name: "junk"}],
          files: [],
          next_token: nil,
          truncated?: false
        }
      }

      move_prefix_report =
        {:ok,
         %{
           total: 2,
           succeeded: 1,
           failed: [%{key: "junk/b", reason: :access_denied}]
         }}

      config = config_with(listings, %{move_prefix: move_prefix_report})
      {:ok, view, _html} = boot(conn, config: config)

      view |> element(~s(button[phx-value-bucket="media"])) |> render_click()
      render_async(view)

      # Move the folder, then confirm with a destination prefix.
      view |> element(~s([phx-click="request_move"][phx-value-key="junk/"])) |> render_click()
      view |> form(~s(form[phx-submit="submit_move"]), %{"dest" => "archive/"}) |> render_submit()
      html = render_async(view)

      assert html =~ "Completed with errors"

      # "Retry failed" must route back to the MOVE modal (non-destructive),
      # never the delete-confirm modal.
      html = view |> element(~s(button[phx-click="retry_failed"])) |> render_click()

      assert html =~ ~s(phx-submit="submit_move")
      refute html =~ ~s(phx-submit="confirm_delete")
    end
  end

  describe "extraction contract" do
    test "lib/lantern is free of host coupling" do
      files = Path.wildcard("lib/lantern_s3/**/*.ex")
      assert files != []

      for path <- files do
        source = File.read!(path)
        refute source =~ "Flicker.", "#{path} must not reference Flicker.*"
        refute source =~ "Application.get_env", "#{path} must not read global app config"
        refute source =~ "Fluxon", "#{path} must not depend on Fluxon"
        refute source =~ "FlickerWeb", "#{path} must not depend on FlickerWeb"
      end
    end
  end
end
