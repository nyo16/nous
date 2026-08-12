defmodule Nous.Agent.CallbacksTest do
  use ExUnit.Case, async: true

  alias Nous.Agent.{Callbacks, Context}

  # The examples use bare `Callbacks`/`Context`, which resolve only through
  # the aliases above.
  doctest Callbacks
end
