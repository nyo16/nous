defmodule Nous.LLMTestHelper do
  @moduledoc """
  Shared helper for LLM integration tests.

  Centralizes model configuration and availability checking.
  Set `TEST_MODEL` env var to override the default model, e.g.:

      TEST_MODEL=openai:gpt-4o-mini mix test --include llm
  """

  @default_model "lmstudio:qwen3-vl-4b-instruct-mlx"

  def test_model, do: System.get_env("TEST_MODEL") || @default_model

  def check_model_available do
    model = Nous.Model.parse(test_model())

    if model.provider == :lmstudio do
      check_lmstudio()
    else
      :ok
    end
  end

  defp check_lmstudio do
    url = System.get_env("LMSTUDIO_BASE_URL") || "http://localhost:1234/v1"

    case Req.get("#{url}/models", receive_timeout: 5_000) do
      {:ok, %{status: 200}} -> :ok
      {:ok, %{status: s}} -> {:error, "LM Studio returned status #{s}"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def skip_if_unavailable(%{skip: reason}) do
    ExUnit.Case.register_attribute(__ENV__, :skip, reason)
    :skip
  end

  def skip_if_unavailable(_), do: :ok
end
