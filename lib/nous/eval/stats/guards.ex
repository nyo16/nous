defmodule Nous.Eval.Stats.Guards do
  @moduledoc false

  # Shared argument guards and option readers for the `Nous.Eval.Stats.*`
  # modules. Public functions there validate inputs and return
  # `{:error, reason}` instead of raising, so every reader here does the same.

  defguard is_count(x) when is_integer(x) and x >= 0

  defguard is_open_unit(p) when is_number(p) and p > 0 and p < 1

  defguard is_unit(p) when is_number(p) and p >= 0 and p <= 1

  @doc false
  @spec confidence(keyword()) :: {:ok, float()} | {:error, :invalid_confidence}
  def confidence(opts) do
    case Keyword.get(opts, :confidence, 0.95) do
      c when is_open_unit(c) -> {:ok, c / 1}
      _ -> {:error, :invalid_confidence}
    end
  end

  @doc false
  @spec probability_opt(keyword(), atom(), float()) ::
          {:ok, float()} | {:error, {:invalid_option, atom()}}
  def probability_opt(opts, key, default) do
    case Keyword.get(opts, key, default) do
      p when is_open_unit(p) -> {:ok, p / 1}
      _ -> {:error, {:invalid_option, key}}
    end
  end

  @doc false
  @spec pos_int_opt(keyword(), atom(), pos_integer()) ::
          {:ok, pos_integer()} | {:error, {:invalid_option, atom()}}
  def pos_int_opt(opts, key, default) do
    case Keyword.get(opts, key, default) do
      n when is_integer(n) and n > 0 -> {:ok, n}
      _ -> {:error, {:invalid_option, key}}
    end
  end

  @doc false
  @spec numbers?(term()) :: boolean()
  def numbers?(list) when is_list(list), do: Enum.all?(list, &is_number/1)
  def numbers?(_), do: false
end
