import Config

config :nous, []

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:agent, :model, :tool]
