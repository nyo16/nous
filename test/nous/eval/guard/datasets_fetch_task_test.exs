defmodule Mix.Tasks.Nous.Eval.Datasets.FetchTest do
  # Mix.shell is global.
  use ExUnit.Case, async: false

  setup do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  test "--list prints the registry with each source's licence status" do
    Mix.Tasks.Nous.Eval.Datasets.Fetch.run(["--list"])

    lines =
      Stream.repeatedly(fn ->
        receive do: ({:mix_shell, :info, [line]} -> line), after: (0 -> nil)
      end)
      |> Enum.take_while(& &1)

    assert Enum.any?(lines, &(&1 =~ ~r/^deepset\/prompt-injections\s+allowed\s+Apache-2.0/))
    assert Enum.any?(lines, &(&1 =~ ~r/^lmsys\/toxic-chat\s+denied\s+CC-BY-NC-4.0/))
    assert Enum.any?(lines, &(&1 =~ ~r/^ai-safety-institute\/AgentHarm\s+terms/))
  end

  test "a denied source exits 2 without downloading" do
    assert catch_exit(Mix.Tasks.Nous.Eval.Datasets.Fetch.run(["lmsys/toxic-chat"])) ==
             {:shutdown, 2}

    assert_received {:mix_shell, :error, [message]}
    assert message =~ "not fetched: CC-BY-NC-4.0"
  end

  test "bad arguments exit 2" do
    assert catch_exit(Mix.Tasks.Nous.Eval.Datasets.Fetch.run(["--bogus"])) == {:shutdown, 2}
    assert_received {:mix_shell, :error, [message]}
    assert message =~ "invalid option --bogus"
  end
end
