defmodule Nous.Session.ConfigTest do
  use ExUnit.Case, async: true

  alias Nous.Session.Config

  test "default values" do
    config = %Config{}
    assert config.max_turns == 10
    assert config.max_budget_tokens == 200_000
    assert config.compact_after_turns == 20
  end

  test "new/1 creates from keyword list" do
    config = Config.new(max_turns: 50, max_budget_tokens: 1_000_000)
    assert config.max_turns == 50
    assert config.max_budget_tokens == 1_000_000
    assert config.compact_after_turns == 20
  end
end
