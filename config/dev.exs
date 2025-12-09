import Config

config :nous,
  log_level: :debug

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:agent, :model, :tool]
