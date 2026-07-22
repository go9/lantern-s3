{:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: LanternS3.PubSub)
{:ok, _} = LanternS3.TestEndpoint.start_link()
ExUnit.start()
