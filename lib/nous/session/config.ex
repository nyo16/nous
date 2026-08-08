defmodule Nous.Session.Config do
  @moduledoc """
  Configuration for managed agent sessions.

  Provides turn limits, token budgets, and compaction thresholds
  for higher-level session management (e.g. `Nous.AgentServer` or
  custom GenServers). This is separate from `Agent.Context.max_iterations`
  which controls the inner agent loop.

  ## Usage

      config = %Nous.Session.Config{
        max_turns: 20,
        max_budget_tokens: 500_000,
        compact_after_turns: 15
      }

      case Nous.Session.Guardrails.check_limits(config, turn_count, in_tokens, out_tokens) do
        :ok -> proceed_with_turn()
        {:error, :max_turns_reached} -> stop_session()
        {:error, :max_budget_reached} -> stop_session()
      end

  ## Why this is not wired into the runner

  Nothing in `lib/` calls `Nous.Session.*`, and that is deliberate rather than
  unfinished: these are pure functions the *caller* composes into its own
  session process, which is why `Nous.Session.Guardrails` documents a GenServer
  integration instead of shipping one. A session's turn and budget policy
  belongs to the application that owns the conversation, not to the agent loop —
  `Agent.Context.max_iterations` already bounds the inner loop, and these bound
  the outer one on whatever schedule the host decides.

  Reviewed and kept in the 2026-08 audit (arch F-11). Do not "wire it up" or
  delete it as dead code without changing that decision first.
  """

  defstruct max_turns: 10,
            max_budget_tokens: 200_000,
            compact_after_turns: 20

  @type t :: %__MODULE__{
          max_turns: pos_integer(),
          max_budget_tokens: pos_integer(),
          compact_after_turns: pos_integer()
        }

  @doc """
  Creates a config from a keyword list.

  ## Examples

      config = Nous.Session.Config.new(max_turns: 50, max_budget_tokens: 1_000_000)

  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    struct(__MODULE__, opts)
  end
end
