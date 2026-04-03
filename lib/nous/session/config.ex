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
