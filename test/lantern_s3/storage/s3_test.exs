defmodule LanternS3.Storage.S3Test do
  use ExUnit.Case, async: false

  alias LanternS3.Storage.S3
  alias LanternS3.Storage.S3.Config

  @moduledoc """
  Unit tests for the OSS-extractable S3 storage adapter.

  ExAws is stubbed at the HTTP-client boundary: we register a fake
  `ExAws.Request.HttpClient` (`LanternS3.Storage.S3Test.FakeHttp`) via
  `config :ex_aws, http_client: ...` for the duration of each test. That keeps
  ExAws's real operation-building, request signing, and XML response parsing in
  the path while serving canned XML responses (no network). The adapter itself
  never sets `http_client` in its per-call overrides — ExAws reads it from its
  own application env — so the adapter stays free of `Application.get_env`.

  Routing is driven by a per-test handler stored in the test process dictionary
  and shared with the fake client via an Agent, so each test fully controls the
  responses for the keys/methods it exercises.
  """

  # ---------------------------------------------------------------------------
  # Fake ExAws HTTP client
  # ---------------------------------------------------------------------------

  defmodule FakeHttp do
    @moduledoc false
    @behaviour ExAws.Request.HttpClient

    @impl true
    def request(method, url, body, _headers, _http_opts) do
      handler = Agent.get(LanternS3.Storage.S3Test.Router, & &1)
      handler.(method, url, body)
    end
  end

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    # A named Agent holds the current per-test request handler so the stateless
    # FakeHttp module (reached by ExAws) can look it up.
    {:ok, pid} = Agent.start_link(fn -> &default_handler/3 end, name: __MODULE__.Router)
    on_exit(fn -> if Process.alive?(pid), do: Agent.stop(pid) end)

    previous = Application.get_env(:ex_aws, :http_client)
    Application.put_env(:ex_aws, :http_client, FakeHttp)

    on_exit(fn ->
      if previous do
        Application.put_env(:ex_aws, :http_client, previous)
      else
        Application.delete_env(:ex_aws, :http_client)
      end
    end)

    config =
      Config.new(
        access_key_id: "AKIATEST",
        secret_access_key: "secret",
        host: "custom.example.com"
      )

    %{config: config}
  end

  defp set_handler(fun), do: Agent.update(__MODULE__.Router, fn _ -> fun end)

  defp default_handler(method, url, _body) do
    raise "unexpected ExAws request: #{method} #{url}"
  end

  defp ok_xml(body), do: {:ok, %{status_code: 200, headers: [], body: body}}

  defp error_403(body \\ "<Error><Code>AccessDenied</Code></Error>"),
    do: {:ok, %{status_code: 403, headers: [], body: body}}

  # ---------------------------------------------------------------------------
  # Config
  # ---------------------------------------------------------------------------

  describe "Config" do
    test "defaults region/scheme and resolves the default host (never the Fly literal)" do
      config = Config.new(access_key_id: "AK", secret_access_key: "SK")

      assert config.region == "auto"
      assert config.scheme == "https://"
      assert Config.host(config) == "t3.storage.dev"
      refute Config.host(config) == "fly.storage.tigris.dev"
    end

    test "host resolution prefers endpoint_url, then host, then default" do
      assert Config.host(
               Config.new(access_key_id: "AK", secret_access_key: "SK", host: "h.example")
             )
             |> Kernel.==("h.example")

      with_endpoint =
        Config.new(
          access_key_id: "AK",
          secret_access_key: "SK",
          host: "h.example",
          endpoint_url: "https://ep.example.com:9000"
        )

      assert Config.host(with_endpoint) == "ep.example.com"
    end
  end

  # ---------------------------------------------------------------------------
  # list/4 shape
  # ---------------------------------------------------------------------------

  describe "list/4" do
    test "returns folders from common prefixes and files with stripped names; excludes the folder-marker self-key",
         %{config: config} do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <ListBucketResult>
        <Name>bucket</Name>
        <Prefix>images/</Prefix>
        <IsTruncated>false</IsTruncated>
        <CommonPrefixes><Prefix>images/thumbnails/</Prefix></CommonPrefixes>
        <Contents>
          <Key>images/</Key>
          <Size>0</Size>
          <LastModified>2026-06-20T00:00:00.000Z</LastModified>
          <ETag>"marker"</ETag>
        </Contents>
        <Contents>
          <Key>images/logo.png</Key>
          <Size>12345</Size>
          <LastModified>2026-06-20T10:00:00.000Z</LastModified>
          <ETag>"abc123"</ETag>
        </Contents>
      </ListBucketResult>
      """

      set_handler(fn :get, _url, _body -> ok_xml(xml) end)

      assert {:ok, listing} = S3.list(config, "bucket", "images/", [])

      assert listing.folders == [%{prefix: "images/thumbnails/", name: "thumbnails"}]

      # The "images/" folder-marker self-key is excluded; only the real file remains.
      assert [file] = listing.files
      assert file.key == "images/logo.png"
      assert file.name == "logo.png"
      assert file.size == 12_345
      assert file.etag == "\"abc123\""
      assert file.last_modified == "2026-06-20T10:00:00.000Z"

      assert listing.next_token == nil
      assert listing.truncated? == false
    end

    test "passes the continuation_token through and surfaces next_token + truncated?", %{
      config: config
    } do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <ListBucketResult>
        <Name>bucket</Name>
        <Prefix></Prefix>
        <IsTruncated>true</IsTruncated>
        <NextContinuationToken>NEXT_TOKEN</NextContinuationToken>
        <Contents>
          <Key>a.txt</Key><Size>1</Size>
          <LastModified>2026-06-20T10:00:00.000Z</LastModified><ETag>"e"</ETag>
        </Contents>
      </ListBucketResult>
      """

      set_handler(fn :get, url, _body ->
        # The continuation token must be propagated to the backend request.
        assert String.contains?(url, "continuation-token=INCOMING") or
                 String.contains?(url, "continuation_token=INCOMING") or
                 String.contains?(url, "INCOMING")

        ok_xml(xml)
      end)

      assert {:ok, listing} =
               S3.list(config, "bucket", "", continuation_token: "INCOMING", max_keys: 50)

      assert listing.truncated? == true
      assert listing.next_token == "NEXT_TOKEN"
      assert [%{key: "a.txt", name: "a.txt"}] = listing.files
    end
  end

  # ---------------------------------------------------------------------------
  # list_buckets/1
  # ---------------------------------------------------------------------------

  describe "list_buckets/1" do
    test "maps bucket names", %{config: config} do
      xml =
        ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
          ~s(<ListAllMyBucketsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">) <>
          "<Owner><ID>owner</ID></Owner><Buckets>" <>
          "<Bucket><Name>one</Name><CreationDate>2026-01-01T00:00:00.000Z</CreationDate></Bucket>" <>
          "<Bucket><Name>two</Name><CreationDate>2026-01-02T00:00:00.000Z</CreationDate></Bucket>" <>
          "</Buckets></ListAllMyBucketsResult>"

      set_handler(fn :get, _url, _body -> ok_xml(xml) end)

      assert {:ok, [%{name: "one"}, %{name: "two"}]} = S3.list_buckets(config)
    end
  end

  # ---------------------------------------------------------------------------
  # delete_many/3
  # ---------------------------------------------------------------------------

  describe "delete_many/3" do
    test "chunks at 1000 keys and aggregates deleted + per-key errors", %{config: config} do
      keys = for i <- 1..1500, do: "k#{i}"

      # Each DeleteObjects request reports the keys it received as deleted, plus
      # one synthetic per-chunk error so we can assert error aggregation.
      set_handler(fn :post, _url, body ->
        chunk_keys = Regex.scan(~r{<Key>([^<]+)</Key>}, body) |> Enum.map(fn [_, k] -> k end)

        deleted_xml =
          chunk_keys
          |> Enum.map(fn k -> "<Deleted><Key>#{k}</Key></Deleted>" end)
          |> Enum.join()

        # Pretend the first key of each chunk failed.
        failed_key = List.first(chunk_keys)

        error_xml =
          "<Error><Key>#{failed_key}</Key><Code>InternalError</Code><Message>boom</Message></Error>"

        ok_xml("<?xml version=\"1.0\"?><DeleteResult>#{deleted_xml}#{error_xml}</DeleteResult>")
      end)

      assert {:ok, %{deleted: deleted, errors: errors}} = S3.delete_many(config, "bucket", keys)

      # 1500 keys → two chunks (1000 + 500).
      assert length(deleted) == 1500
      assert length(errors) == 2
      assert Enum.all?(errors, &(&1.code == "InternalError"))
      assert "k1" in Enum.map(errors, & &1.key)
      assert "k1001" in Enum.map(errors, & &1.key)
    end
  end

  # ---------------------------------------------------------------------------
  # move/4
  # ---------------------------------------------------------------------------

  describe "move/4" do
    test "copy + delete success yields a clean op_report", %{config: config} do
      set_handler(fn
        :put, _url, _body -> ok_xml("<CopyObjectResult><ETag>\"x\"</ETag></CopyObjectResult>")
        :delete, _url, _body -> ok_xml("")
      end)

      assert {:ok, report} = S3.move(config, "bucket", "a/old.txt", "b/new.txt")
      assert report == %{total: 1, succeeded: 1, failed: []}
    end

    test "copy ok but delete fails is reported as :copy_ok_delete_failed", %{config: config} do
      set_handler(fn
        :put, _url, _body -> ok_xml("<CopyObjectResult><ETag>\"x\"</ETag></CopyObjectResult>")
        :delete, _url, _body -> error_403()
      end)

      assert {:ok, report} = S3.move(config, "bucket", "a/old.txt", "b/new.txt")
      assert report.total == 1
      assert report.succeeded == 0
      assert report.failed == [%{key: "a/old.txt", reason: :copy_ok_delete_failed}]
    end
  end

  # ---------------------------------------------------------------------------
  # move_prefix/4 + delete_prefix/3 (recursive, non-atomic)
  # ---------------------------------------------------------------------------

  describe "move_prefix/4" do
    test "walks the prefix and returns an op_report with rebased destinations", %{config: config} do
      list_xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <ListBucketResult>
        <Name>bucket</Name><Prefix>src/</Prefix><IsTruncated>false</IsTruncated>
        <Contents><Key>src/a.txt</Key><Size>1</Size>
          <LastModified>2026-06-20T00:00:00Z</LastModified><ETag>"a"</ETag></Contents>
        <Contents><Key>src/sub/b.txt</Key><Size>1</Size>
          <LastModified>2026-06-20T00:00:00Z</LastModified><ETag>"b"</ETag></Contents>
      </ListBucketResult>
      """

      copied = :ets.new(:copied, [:public, :set])

      set_handler(fn
        :get, _url, _body ->
          ok_xml(list_xml)

        :put, url, _body ->
          :ets.insert(copied, {url, true})
          ok_xml("<CopyObjectResult><ETag>\"x\"</ETag></CopyObjectResult>")

        :delete, _url, _body ->
          ok_xml("")
      end)

      assert {:ok, report} = S3.move_prefix(config, "bucket", "src/", "dest/")
      assert report.total == 2
      assert report.succeeded == 2
      assert report.failed == []

      # Destinations were rebased under dest/ (assert via the copy URL targets).
      urls = :ets.tab2list(copied) |> Enum.map(fn {u, _} -> u end) |> Enum.join(" ")
      assert urls =~ "dest/a.txt"
      assert urls =~ "dest/sub/b.txt"
    end
  end

  describe "delete_prefix/3" do
    test "paginates the whole prefix and never raises mid-walk", %{config: config} do
      page1 = """
      <?xml version="1.0" encoding="UTF-8"?>
      <ListBucketResult>
        <Name>bucket</Name><Prefix>p/</Prefix><IsTruncated>true</IsTruncated>
        <NextContinuationToken>PAGE2</NextContinuationToken>
        <Contents><Key>p/a</Key><Size>1</Size>
          <LastModified>x</LastModified><ETag>"a"</ETag></Contents>
      </ListBucketResult>
      """

      page2 = """
      <?xml version="1.0" encoding="UTF-8"?>
      <ListBucketResult>
        <Name>bucket</Name><Prefix>p/</Prefix><IsTruncated>false</IsTruncated>
        <Contents><Key>p/b</Key><Size>1</Size>
          <LastModified>x</LastModified><ETag>"b"</ETag></Contents>
      </ListBucketResult>
      """

      set_handler(fn
        :get, url, _body ->
          if String.contains?(url, "PAGE2"), do: ok_xml(page2), else: ok_xml(page1)

        :delete, url, _body ->
          # p/b's delete fails; the walk must continue and report it.
          if String.contains?(url, "p/b"), do: error_403(), else: ok_xml("")
      end)

      assert {:ok, report} = S3.delete_prefix(config, "bucket", "p/")
      assert report.total == 2
      assert report.succeeded == 1
      assert [%{key: "p/b"}] = report.failed
    end
  end

  # ---------------------------------------------------------------------------
  # presigned URLs
  # ---------------------------------------------------------------------------

  describe "presigned URLs" do
    test "presigned_get/4 and presigned_put/4 target the configured host (never the Fly literal)",
         %{config: config} do
      assert {:ok, get_url} = S3.presigned_get(config, "bucket", "k.png", expires_in: 60)
      assert {:ok, put_url} = S3.presigned_put(config, "bucket", "k.png", expires_in: 60)

      assert get_url =~ "custom.example.com"
      assert put_url =~ "custom.example.com"
      refute get_url =~ "fly.storage.tigris.dev"
      refute put_url =~ "fly.storage.tigris.dev"
      assert get_url =~ "X-Amz-Signature"
      assert put_url =~ "X-Amz-Signature"
    end

    test "presigned_put/4 with content_type encodes it as a signed query param", %{config: config} do
      assert {:ok, url} =
               S3.presigned_put(config, "bucket", "k.png",
                 content_type: "image/png",
                 expires_in: 60
               )

      assert url =~ "Content-Type"
    end
  end

  # ---------------------------------------------------------------------------
  # head/3 + put_object/5 + copy/4
  # ---------------------------------------------------------------------------

  describe "head/3, put_object/5, copy/4" do
    test "head returns ok on 200", %{config: config} do
      set_handler(fn :head, _url, _body ->
        {:ok, %{status_code: 200, headers: [{"content-length", "5"}], body: ""}}
      end)

      assert {:ok, _} = S3.head(config, "bucket", "k")
    end

    test "put_object writes a zero-byte folder marker", %{config: config} do
      set_handler(fn :put, _url, body ->
        assert body == "" or body == <<>>
        ok_xml("")
      end)

      assert {:ok, _} = S3.put_object(config, "bucket", "folder/", "", [])
    end

    test "copy issues a server-side put_object_copy", %{config: config} do
      set_handler(fn :put, _url, _body ->
        ok_xml("<CopyObjectResult><ETag>\"x\"</ETag></CopyObjectResult>")
      end)

      assert {:ok, _} = S3.copy(config, "bucket", "a/old", "b/new")
    end
  end

  # ---------------------------------------------------------------------------
  # OSS-extraction contract
  # ---------------------------------------------------------------------------

  describe "OSS-extraction contract" do
    test "the storage modules contain no Flicker. references and no Application.get_env" do
      files = [
        "lib/lantern_s3/storage.ex",
        "lib/lantern_s3/storage/s3.ex",
        "lib/lantern_s3/storage/s3/config.ex"
      ]

      for relative <- files do
        source = File.read!(Path.join(File.cwd!(), relative))

        refute source =~ "Flicker.",
               "#{relative} must not reference any Flicker.* context (OSS-extraction contract)"

        refute source =~ "Application.get_env",
               "#{relative} must not read Application.get_env (config is injected)"
      end
    end
  end
end
