defmodule LanternS3.TestEndpoint do
  # Minimal Phoenix endpoint so `live_isolated/3` can mount the components in tests.
  use Phoenix.Endpoint, otp_app: :lantern_s3

  socket "/live", Phoenix.LiveView.Socket
end
