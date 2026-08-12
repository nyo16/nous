defmodule Nous.Agent.ContextTest do
  use ExUnit.Case, async: true

  alias Nous.Agent.Context
  alias Nous.{Message, Usage}

  # The examples use bare `Context`/`Message`/`Usage`, which resolve only
  # through the aliases above.
  doctest Context
end
