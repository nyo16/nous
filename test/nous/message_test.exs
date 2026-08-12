defmodule Nous.MessageTest do
  use ExUnit.Case, async: true

  alias Nous.Message
  alias Nous.Message.ContentPart

  # The examples use bare `Message`/`ContentPart`, which resolve only through
  # the aliases above.
  doctest Message
end
