defmodule LanternS3.ScopeTest do
  use ExUnit.Case, async: true

  alias LanternS3.Scope

  defp scope(attrs \\ []) do
    Scope.new(Keyword.merge([adapter: __MODULE__, config: %{}], attrs))
  end

  describe "root_prefix normalization" do
    test "defaults to \"\" (the whole bucket)" do
      assert scope().root_prefix == ""
    end

    test "adds a trailing slash and strips a leading one" do
      assert scope(root_prefix: "sessions/abc").root_prefix == "sessions/abc/"
      assert scope(root_prefix: "/sessions/abc/").root_prefix == "sessions/abc/"
      assert scope(root_prefix: "sessions/abc/").root_prefix == "sessions/abc/"
    end

    test "nil normalizes to \"\"" do
      assert scope(root_prefix: nil).root_prefix == ""
    end
  end

  describe "injectable upload adapter + limits" do
    test "defaults: no upload adapter override, empty opts" do
      s = scope()
      assert s.upload_adapter == nil
      assert s.upload_opts == %{}
    end

    test "carries a custom upload adapter + limit opts" do
      s =
        scope(
          upload_adapter: SomeGatedAdapter,
          upload_opts: %{accept: ~w(.png), max_entries: 5, max_file_size: 5_242_880}
        )

      assert s.upload_adapter == SomeGatedAdapter
      assert s.upload_opts.max_entries == 5
    end
  end

  describe "within_root?/2 — the navigation guard" do
    test "no root granted → every prefix is allowed" do
      s = scope()
      assert Scope.within_root?(s, "")
      assert Scope.within_root?(s, "anything/at/all/")
    end

    test "with a root, only at-or-below is allowed" do
      s = scope(root_prefix: "sessions/abc/")
      assert Scope.within_root?(s, "sessions/abc/")
      assert Scope.within_root?(s, "sessions/abc/nested/")
    end

    test "rejects the bucket root, a sibling prefix, and a prefix-collision neighbour" do
      s = scope(root_prefix: "sessions/abc/")
      refute Scope.within_root?(s, "")
      refute Scope.within_root?(s, "sessions/")
      refute Scope.within_root?(s, "sessions/xyz/")
      # "sessions/abcdef/" must not slip past because it *starts with* "sessions/abc"
      refute Scope.within_root?(s, "sessions/abcdef/")
    end
  end
end
