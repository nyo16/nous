import Config

config :yggdrasil,
  log_level: :warning,
  enable_telemetry: false

config :logger, :console,
  format: "$message\n",
  level: :warning
