defmodule Nous.Eval.Online.Salt do
  @moduledoc false
  # The `:sampling_salt` secret, opaque wherever it travels: the config,
  # the handler config (`:telemetry.list_handlers/1`), Registry and
  # Coordinator state, job contexts and so crash reports. `inspect/2` hides
  # it, and the secret sits in a closure, which Erlang term formatting
  # prints as `#Fun<...>`. Only `Nous.Eval.Online.Sampler` reads it.

  @derive {Inspect, except: [:secret]}
  @enforce_keys [:secret]
  defstruct [:secret]

  @type t :: %__MODULE__{secret: (-> binary())}

  @spec new(binary()) :: t()
  def new(salt) when is_binary(salt), do: %__MODULE__{secret: fn -> salt end}
end
