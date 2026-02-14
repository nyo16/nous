defmodule Nous.Eval.Evaluators.ToolUsage do
  @moduledoc """
  Evaluator that verifies correct tool usage by the agent.

  ## Expected Format

      %{
        tools_called: ["tool_name1", "tool_name2"],
        tools_not_called: ["tool_name3"],
        output_contains: ["expected", "text"],
        min_tool_calls: 1,
        max_tool_calls: 5,
        tool_args: %{
          "tool_name" => %{"arg1" => "value1"}
        }
      }

  All fields are optional.

  ## Configuration

    * `:strict_order` - Tools must be called in order (default: false)
    * `:check_args` - Verify tool arguments (default: true if tool_args provided)

  ## Examples

      # Verify specific tools were called
      TestCase.new(
        id: "tool_test",
        input: "What's the weather in Tokyo?",
        expected: %{
          tools_called: ["get_weather"],
          output_contains: ["Tokyo"]
        },
        eval_type: :tool_usage
      )

      # Verify tool call count
      TestCase.new(
        id: "multi_tool",
        input: "Compare weather in Tokyo and Paris",
        expected: %{
          tools_called: ["get_weather"],
          min_tool_calls: 2
        },
        eval_type: :tool_usage
      )

  """

  @behaviour Nous.Eval.Evaluator

  @impl true
  def evaluate(actual, expected, config) do
    # actual should contain the agent result with tool call information
    tool_calls = extract_tool_calls(actual)
    output = extract_output(actual)

    checks = [
      check_tools_called(tool_calls, expected),
      check_tools_not_called(tool_calls, expected),
      check_tool_count(tool_calls, expected),
      check_tool_args(tool_calls, expected, config),
      check_output_contains(output, expected)
    ]

    # Combine results
    failed_checks = Enum.filter(checks, fn {passed, _, _} -> not passed end)

    if failed_checks == [] do
      %{
        score: 1.0,
        passed: true,
        reason: nil,
        details: %{
          tools_called: Enum.map(tool_calls, & &1.name),
          tool_count: length(tool_calls)
        }
      }
    else
      reasons = Enum.map(failed_checks, fn {_, reason, _} -> reason end)
      details = Enum.reduce(failed_checks, %{}, fn {_, _, d}, acc -> Map.merge(acc, d) end)

      # Calculate partial score
      passed_count = length(checks) - length(failed_checks)
      score = passed_count / length(checks)

      %{
        score: score,
        passed: false,
        reason: Enum.join(reasons, "; "),
        details:
          Map.merge(details, %{
            tools_called: Enum.map(tool_calls, & &1.name),
            tool_count: length(tool_calls)
          })
      }
    end
  end

  @impl true
  def name, do: "Tool Usage"

  defp extract_tool_calls(actual) when is_map(actual) do
    # Try different possible structures
    cond do
      Map.has_key?(actual, :agent_result) ->
        extract_from_agent_result(actual.agent_result)

      Map.has_key?(actual, :all_messages) ->
        extract_from_messages(actual.all_messages)

      Map.has_key?(actual, :context) and is_map(actual.context) ->
        extract_from_context(actual.context)

      true ->
        []
    end
  end

  defp extract_tool_calls(_), do: []

  defp extract_from_agent_result(result) when is_map(result) do
    cond do
      Map.has_key?(result, :all_messages) ->
        extract_from_messages(result.all_messages)

      Map.has_key?(result, :context) ->
        extract_from_context(result.context)

      true ->
        []
    end
  end

  defp extract_from_agent_result(_), do: []

  defp extract_from_messages(messages) when is_list(messages) do
    messages
    |> Enum.flat_map(fn msg ->
      case msg do
        %{role: :assistant, tool_calls: calls} when is_list(calls) ->
          Enum.map(calls, fn call ->
            %{
              name: call[:name] || call["name"],
              args: call[:args] || call["args"] || call[:arguments] || call["arguments"]
            }
          end)

        _ ->
          []
      end
    end)
  end

  defp extract_from_messages(_), do: []

  defp extract_from_context(context) when is_map(context) do
    case Map.get(context, :messages) do
      messages when is_list(messages) -> extract_from_messages(messages)
      _ -> []
    end
  end

  defp extract_from_context(_), do: []

  defp extract_output(actual) when is_map(actual) do
    cond do
      Map.has_key?(actual, :output) -> to_string(actual.output)
      Map.has_key?(actual, :agent_result) -> extract_output(actual.agent_result)
      true -> ""
    end
  end

  defp extract_output(actual), do: to_string(actual)

  defp check_tools_called(tool_calls, expected) do
    required_tools = get_list(expected, :tools_called, [])

    if required_tools == [] do
      {true, nil, %{}}
    else
      called_names = Enum.map(tool_calls, & &1.name) |> Enum.uniq()
      missing = required_tools -- called_names

      if missing == [] do
        {true, nil, %{}}
      else
        {false, "Expected tools not called: #{inspect(missing)}", %{missing_tools: missing}}
      end
    end
  end

  defp check_tools_not_called(tool_calls, expected) do
    forbidden_tools = get_list(expected, :tools_not_called, [])

    if forbidden_tools == [] do
      {true, nil, %{}}
    else
      called_names = Enum.map(tool_calls, & &1.name) |> Enum.uniq()
      forbidden_called = Enum.filter(forbidden_tools, &(&1 in called_names))

      if forbidden_called == [] do
        {true, nil, %{}}
      else
        {false, "Forbidden tools were called: #{inspect(forbidden_called)}",
         %{forbidden_called: forbidden_called}}
      end
    end
  end

  defp check_tool_count(tool_calls, expected) do
    count = length(tool_calls)
    min_calls = get_number(expected, :min_tool_calls)
    max_calls = get_number(expected, :max_tool_calls)

    cond do
      min_calls && count < min_calls ->
        {false, "Expected at least #{min_calls} tool calls, got #{count}",
         %{expected_min: min_calls, actual: count}}

      max_calls && count > max_calls ->
        {false, "Expected at most #{max_calls} tool calls, got #{count}",
         %{expected_max: max_calls, actual: count}}

      true ->
        {true, nil, %{}}
    end
  end

  defp check_tool_args(tool_calls, expected, config) do
    expected_args = get_map(expected, :tool_args, %{})
    check_args = Map.get(config, :check_args, expected_args != %{})

    if not check_args or expected_args == %{} do
      {true, nil, %{}}
    else
      mismatches =
        Enum.reduce(expected_args, [], fn {tool_name, expected_tool_args}, acc ->
          # Find calls to this tool
          calls = Enum.filter(tool_calls, fn tc -> tc.name == tool_name end)

          if calls == [] do
            [{tool_name, :not_called} | acc]
          else
            # Check if any call matches expected args
            matches =
              Enum.any?(calls, fn call ->
                args_match?(call.args, expected_tool_args)
              end)

            if matches, do: acc, else: [{tool_name, :args_mismatch} | acc]
          end
        end)

      if mismatches == [] do
        {true, nil, %{}}
      else
        {false, "Tool argument mismatches: #{inspect(mismatches)}", %{arg_mismatches: mismatches}}
      end
    end
  end

  defp check_output_contains(output, expected) do
    patterns = get_list(expected, :output_contains, [])

    if patterns == [] do
      {true, nil, %{}}
    else
      output_lower = String.downcase(output)

      missing =
        Enum.reject(patterns, fn pattern ->
          String.contains?(output_lower, String.downcase(pattern))
        end)

      if missing == [] do
        {true, nil, %{}}
      else
        {false, "Output missing expected content: #{inspect(missing)}",
         %{missing_output: missing}}
      end
    end
  end

  defp args_match?(actual_args, expected_args)
       when is_map(actual_args) and is_map(expected_args) do
    Enum.all?(expected_args, fn {key, value} ->
      actual_value = Map.get(actual_args, key) || Map.get(actual_args, to_string(key))
      actual_value == value
    end)
  end

  defp args_match?(_, _), do: false

  defp get_list(map, key, default) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key)) || default
  end

  defp get_list(_, _, default), do: default

  defp get_number(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp get_number(_, _), do: nil

  defp get_map(map, key, default) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key)) || default
  end

  defp get_map(_, _, default), do: default
end
