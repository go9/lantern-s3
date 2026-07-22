defmodule LanternS3.ConnCase do
  @moduledoc "Test conn + endpoint for LiveComponent tests (live_isolated)."
  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      @endpoint LanternS3.TestEndpoint
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
