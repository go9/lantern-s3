import Config

config :lantern_s3, LanternS3.TestEndpoint,
  secret_key_base: String.duplicate("a", 64),
  live_view: [signing_salt: "lanterns3test"],
  pubsub_server: LanternS3.PubSub,
  server: false

config :phoenix, :json_library, Jason
config :logger, level: :warning
