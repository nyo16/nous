defmodule Nous.Eval.Examples.BasicTest do
  # async: true - the example installs its scripted model as the calling
  # process's dispatcher override, which no other test can see.
  use ExUnit.Case, async: true

  alias Nous.Eval.Examples.Basic

  @moduletag :capture_log

  test "runs offline with the scripted model and passes every case" do
    assert {:ok, run} = Nous.Eval.run(Basic, k: 2, seed: 7)

    assert run.status == :completed
    assert length(run.samples) == 10
    assert Enum.all?(run.samples, &(&1.verdict == :pass))
    assert run.fingerprint["seed_forwarded"] == true

    tokyo = Enum.find(run.samples, &(&1.case_id == "weather-tokyo"))

    assert [%{name: "get_weather", arguments: %{"city" => "Tokyo"}}] =
             Nous.Eval.Trace.tool_calls(tokyo.trace)

    # teardown/1 removed the override it installed.
    assert Nous.ModelDispatcher.resolve() == Nous.ModelDispatcher
  end

  test "an installed dispatcher is left alone" do
    Nous.ModelDispatcher.put_dispatcher(__MODULE__)
    assert {:ok, %{installed?: false} = state} = Basic.setup([])
    Basic.teardown(state)
    assert Nous.ModelDispatcher.resolve() == __MODULE__
  end
end
