defmodule LanternS3.UploaderTest do
  use LanternS3.ConnCase, async: true

  import Phoenix.LiveViewTest

  # Stub Uploader.Adapter — returns a fixed external meta map so tests never
  # hit real storage.
  defmodule StubAdapter do
    @behaviour LanternS3.Uploader.Adapter

    @impl true
    def presign(_config, entry, _opts) do
      key = Map.get(entry, :filename, "file")

      {:ok,
       %{
         uploader: "S3",
         key: "uploads/#{key}",
         url: "http://example.test/put/#{key}"
       }}
    end
  end

  # Minimal host LiveView that mounts the Uploader with session-driven assigns.
  defmodule HostLive do
    use Phoenix.LiveView

    def mount(_params, session, socket) do
      socket =
        socket
        |> Phoenix.Component.assign(:adapter, session["adapter"] || StubAdapter)
        |> Phoenix.Component.assign(:adapter_config, session["adapter_config"] || %{})
        |> Phoenix.Component.assign(:accept, session["accept"] || :any)
        |> Phoenix.Component.assign(:max_entries, session["max_entries"] || 20)
        |> Phoenix.Component.assign(:max_file_size, session["max_file_size"] || 50_000_000)
        |> Phoenix.Component.assign(:hint, session["hint"])
        |> Phoenix.Component.assign(:on_event, session["on_event"])

      {:ok, socket}
    end

    def render(assigns) do
      ~H"""
      <.live_component
        module={LanternS3.Uploader}
        id="uploader-test"
        adapter={@adapter}
        adapter_config={@adapter_config}
        accept={@accept}
        max_entries={@max_entries}
        max_file_size={@max_file_size}
        hint={@hint}
        on_event={@on_event}
      />
      """
    end
  end

  defp boot(conn, opts \\ []) do
    session = %{
      "adapter" => Keyword.get(opts, :adapter, StubAdapter),
      "adapter_config" => Keyword.get(opts, :adapter_config, %{}),
      "accept" => Keyword.get(opts, :accept, :any),
      "max_entries" => Keyword.get(opts, :max_entries, 20),
      "max_file_size" => Keyword.get(opts, :max_file_size, 50_000_000),
      "hint" => Keyword.get(opts, :hint),
      "on_event" => Keyword.get(opts, :on_event)
    }

    live_isolated(conn, HostLive, session: session)
  end

  describe "dropzone" do
    test "renders title, auto-derived hint, and file input", %{conn: conn} do
      {:ok, view, html} = boot(conn)

      assert html =~ "Choose a file or drag &amp; drop it here"
      assert html =~ "JPEG, PNG, PDF, and MP4 formats, up to 50 MB."
      assert html =~ ~s(type="file")
      assert has_element?(view, "label.lt-dropzone-browse")
      assert has_element?(view, "#uploader-test-form")
    end

    test "uses an explicit hint when provided", %{conn: conn} do
      {:ok, _view, html} = boot(conn, hint: "Only PDFs, up to 10 MB.")

      assert html =~ "Only PDFs, up to 10 MB."
      refute html =~ "JPEG, PNG, PDF, and MP4"
    end

    test "Clear all is absent when there are no completed items", %{conn: conn} do
      {:ok, view, html} = boot(conn)

      refute html =~ "Clear all"
      refute has_element?(view, ~s(button[phx-click="clear_all"]))
    end
  end

  describe "upload rows" do
    test "a simulated upload appears as a row", %{conn: conn} do
      {:ok, view, _html} = boot(conn)

      upload =
        file_input(view, "#uploader-test-form", :files, [
          %{
            name: "photo.png",
            content: :binary.copy(<<0>>, 1024),
            type: "image/png"
          }
        ])

      # Drive the external entry through progress; LiveViewTest does not run JS.
      assert render_upload(upload, "photo.png", 50) =~ "photo.png"
      html = render(view)

      assert html =~ "photo.png"
      assert html =~ "Uploading"
      assert html =~ "PNG"
      assert has_element?(view, ~s(button[phx-click="cancel_upload"]))
    end

    test "completed upload persists with Clear controls", %{conn: conn} do
      {:ok, view, _html} = boot(conn)

      upload =
        file_input(view, "#uploader-test-form", :files, [
          %{
            name: "report.pdf",
            content: :binary.copy(<<1>>, 2048),
            type: "application/pdf"
          }
        ])

      html = render_upload(upload, "report.pdf", 100)

      assert html =~ "report.pdf"
      assert html =~ "Completed"
      assert html =~ "Clear all"
      assert has_element?(view, ~s(button[phx-click="clear"][phx-value-key="uploads/report.pdf"]))

      # Clear the single completed row (UI-only — nothing is deleted from storage).
      view
      |> element(~s(button[phx-click="clear"][phx-value-key="uploads/report.pdf"]))
      |> render_click()

      html = render(view)
      refute html =~ "report.pdf"
      refute html =~ "Clear all"
    end
  end

  defmodule StorageStub do
    def presigned_put(_config, bucket, key, opts) do
      send(self(), {:presigned_put, bucket, key, opts})
      {:ok, "https://s3.example/put"}
    end
  end

  describe "S3Adapter" do
    test "builds meta from a storage adapter presigned_put" do
      config = %{
        storage_adapter: StorageStub,
        storage_config: %{region: "us-east-1"},
        bucket: "media",
        prefix: "docs/"
      }

      assert {:ok, meta} =
               LanternS3.Uploader.S3Adapter.presign(
                 config,
                 %{filename: "readme.txt", content_type: "text/plain"},
                 []
               )

      assert meta == %{
               uploader: "S3",
               key: "docs/readme.txt",
               url: "https://s3.example/put"
             }

      assert_received {:presigned_put, "media", "docs/readme.txt", opts}
      assert opts[:content_type] == "text/plain"
      assert opts[:expires_in] == 3600
    end
  end
end
