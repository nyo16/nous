defmodule Nous.Session.Guardrails do
  @moduledoc """
  Session limit checking and guardrail functions.

  Works with `Nous.Session.Config` to enforce turn limits,
  token budgets, and compaction triggers.

  ## Example: GenServer integration

      defmodule MySession do
        use GenServer

        def handle_call({:send, message}, _from, state) do
          case Guardrails.check_limits(state.config, state.turns, state.in_tokens, state.out_tokens) do
            :ok ->
              # proceed with agent call
              ...
            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
        end
      end

  """

  alias Nous.Session.Config

  @doc """
  Checks whether a session has exceeded its configured limits.

  Returns `:ok` if within limits, or `{:error, reason}` if a limit is hit.

  ## Examples

      iex> config = %Nous.Session.Config{max_turns: 10, max_budget_tokens: 100_000}
      iex> Nous.Session.Guardrails.check_limits(config, 5, 1000, 2000)
      :ok

      iex> config = %Nous.Session.Config{max_turns: 10, max_budget_tokens: 100_000}
      iex> Nous.Session.Guardrails.check_limits(config, 10, 1000, 2000)
      {:error, :max_turns_reached}

  """
  @spec check_limits(Config.t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, :max_turns_reached | :max_budget_reached}
  def check_limits(%Config{} = config, turn_count, input_tokens, output_tokens) do
    cond do
      turn_count >= config.max_turns ->
        {:error, :max_turns_reached}

      input_tokens + output_tokens >= config.max_budget_tokens ->
        {:error, :max_budget_reached}

      true ->
        :ok
    end
  end

  @doc """
  Checks if the session should trigger compaction.

  ## Examples

      iex> config = %Nous.Session.Config{compact_after_turns: 20}
      iex> Nous.Session.Guardrails.should_compact?(config, 25)
      true

      iex> config = %Nous.Session.Config{compact_after_turns: 20}
      iex> Nous.Session.Guardrails.should_compact?(config, 15)
      false

  """
  @spec should_compact?(Config.t(), non_neg_integer()) :: boolean()
  def should_compact?(%Config{compact_after_turns: threshold}, turn_count) do
    turn_count > threshold
  end

  @doc """
  Returns remaining budget as `{remaining_turns, remaining_tokens}`.

  ## Examples

      iex> config = %Nous.Session.Config{max_turns: 10, max_budget_tokens: 100_000}
      iex> Nous.Session.Guardrails.remaining(config, 3, 5000, 10000)
      {7, 85000}

  """
  @spec remaining(Config.t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {non_neg_integer(), non_neg_integer()}
  def remaining(%Config{} = config, turn_count, input_tokens, output_tokens) do
    remaining_turns = max(0, config.max_turns - turn_count)
    remaining_tokens = max(0, config.max_budget_tokens - (input_tokens + output_tokens))
    {remaining_turns, remaining_tokens}
  end

  @doc """
  Returns a summary map of the session's current state against its limits.

  Useful for logging or exposing session health to users.

  ## Examples

      Nous.Session.Guardrails.summary(config, 5, 10_000, 20_000)
      #=> %{
      #=>   turns: %{current: 5, max: 10, remaining: 5},
      #=>   tokens: %{used: 30_000, max: 200_000, remaining: 170_000},
      #=>   needs_compaction: false
      #=> }

  """
  @spec summary(Config.t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: map()
  def summary(%Config{} = config, turn_count, input_tokens, output_tokens) do
    used_tokens = input_tokens + output_tokens
    {rem_turns, rem_tokens} = remaining(config, turn_count, input_tokens, output_tokens)

    %{
      turns: %{current: turn_count, max: config.max_turns, remaining: rem_turns},
      tokens: %{used: used_tokens, max: config.max_budget_tokens, remaining: rem_tokens},
      needs_compaction: should_compact?(config, turn_count)
    }
  end
end
