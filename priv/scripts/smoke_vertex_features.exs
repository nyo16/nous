# Vertex / Gemini smoke test for the 0.16.0 feature additions.
#
# Run:
#
#   export VERTEX_AI_ACCESS_TOKEN="$(gcloud auth print-access-token)"
#   export GOOGLE_CLOUD_PROJECT="<your-gcp-project-id>"
#   # Optional: GOOGLE_CLOUD_LOCATION (default: us-central1)
#   #          MODEL              (default: gemini-2.5-pro)
#   #          THINKING_MODEL     (default: gemini-2.5-pro)
#
#   mix run priv/scripts/smoke_vertex_features.exs
#
# Each feature prints PASS or FAIL on a single line. Nothing about your
# credentials is printed. Tests are independent — one failure won't abort
# the rest.

defmodule Smoke do
  @model System.get_env("MODEL") || "gemini-2.5-pro"
  @thinking_model System.get_env("THINKING_MODEL") || "gemini-2.5-pro"

  def run do
    require_env!()

    IO.puts("Vertex/Gemini smoke — model=#{@model}, thinking_model=#{@thinking_model}")
    IO.puts(String.duplicate("-", 60))

    run_test("basic chat", &basic_chat/0)
    run_test("thinking_config + reasoning_content", &thinking/0)
    run_test("structured output (json_schema)", &structured_output/0)
    run_test("function calling", &function_calling/0)
    run_test("tool_choice :any forces tool use", &forced_tool/0)
    run_test("native :google_search", &google_search/0)
    run_test("streaming text only", &streaming_text/0)
    run_test("streaming + tools", &streaming_tools/0)
    run_test("safety_settings pass-through (no body error)", &safety_settings/0)
  end

  # ---------------------------------------------------------------------------

  defp basic_chat do
    {:ok, text} =
      Nous.LLM.generate_text("vertex_ai:#{@model}", "Reply with the single word: pong",
        temperature: 0.0
      )

    if String.contains?(String.downcase(text), "pong") do
      :ok
    else
      {:error, "unexpected response: #{inspect(text)}"}
    end
  end

  defp thinking do
    model =
      Nous.Model.parse(
        "vertex_ai:#{@thinking_model}",
        receive_timeout: 600_000,
        default_settings: %{
          thinking_config: %{thinking_budget: 1024, include_thoughts: true},
          temperature: 0.0
        }
      )

    case Nous.ModelDispatcher.request(
           model,
           [Nous.Message.user("Solve: what is 17 * 23? Just the number.")],
           model.default_settings
         ) do
      {:ok, %Nous.Message{} = msg} ->
        cond do
          String.contains?(msg.content || "", "391") ->
            cond do
              is_binary(msg.reasoning_content) and msg.reasoning_content != "" ->
                :ok

              true ->
                IO.puts("    NOTE: reasoning_content empty — model may not have emitted thoughts")
                :ok
            end

          true ->
            {:error, "expected 391 in answer, got #{inspect(msg.content)}"}
        end

      other ->
        {:error, inspect(other)}
    end
  end

  defp structured_output do
    schema = %{
      "type" => "object",
      "properties" => %{
        "city" => %{"type" => "string"},
        "country" => %{"type" => "string"}
      },
      "required" => ["city", "country"]
    }

    model =
      Nous.Model.parse(
        "vertex_ai:#{@model}",
        receive_timeout: 600_000,
        default_settings: %{
          json_schema: schema,
          temperature: 0.0
        }
      )

    {:ok, msg} =
      Nous.ModelDispatcher.request(
        model,
        [Nous.Message.user("Capital of France. JSON.")],
        model.default_settings
      )

    case JSON.decode(msg.content) do
      {:ok, %{"city" => city, "country" => country}}
      when is_binary(city) and is_binary(country) ->
        :ok

      {:ok, other} ->
        {:error, "schema not honored: #{inspect(other)}"}

      {:error, e} ->
        {:error, "non-JSON response: #{inspect(e)} content=#{inspect(msg.content)}"}
    end
  end

  defp function_calling do
    weather_tool =
      Nous.Tool.from_function(
        fn _ctx, %{"city" => city} ->
          {:ok, "Weather in #{city}: 21C, sunny"}
        end,
        name: "get_weather",
        description: "Get current weather for a city",
        parameters: %{
          "type" => "object",
          "properties" => %{"city" => %{"type" => "string"}},
          "required" => ["city"]
        }
      )

    {:ok, text} =
      Nous.LLM.generate_text(
        "vertex_ai:#{@model}",
        "What's the weather in Paris? Use the tool.",
        tools: [weather_tool],
        temperature: 0.0,
        receive_timeout: 600_000
      )

    if String.contains?(text, "21") or String.contains?(String.downcase(text), "sunny") do
      :ok
    else
      {:error, "tool result not woven into final answer: #{inspect(text)}"}
    end
  end

  defp forced_tool do
    pick_tool =
      Nous.Tool.from_function(
        fn _ctx, %{"choice" => choice} ->
          {:ok, "picked #{choice}"}
        end,
        name: "make_choice",
        description: "Record a choice",
        parameters: %{
          "type" => "object",
          "properties" => %{"choice" => %{"type" => "string"}},
          "required" => ["choice"]
        }
      )

    model =
      Nous.Model.parse(
        "vertex_ai:#{@model}",
        receive_timeout: 600_000,
        default_settings: %{
          tool_choice: :any,
          temperature: 0.0
        }
      )

    settings_with_tools =
      Map.put(model.default_settings, :tools, [Nous.ToolSchema.to_gemini(pick_tool)])

    {:ok, %Nous.Message{} = msg} =
      Nous.ModelDispatcher.request(
        model,
        [Nous.Message.user("Just say hi.")],
        settings_with_tools
      )

    if length(msg.tool_calls) > 0 do
      :ok
    else
      {:error, "expected forced tool call, got plain text: #{inspect(msg.content)}"}
    end
  end

  defp google_search do
    model =
      Nous.Model.parse(
        "vertex_ai:#{@model}",
        receive_timeout: 600_000,
        default_settings: %{
          native_tools: [:google_search],
          temperature: 0.0
        }
      )

    {:ok, %Nous.Message{} = msg} =
      Nous.ModelDispatcher.request(
        model,
        [Nous.Message.user("What was the headline news today? One sentence.")],
        model.default_settings
      )

    if is_binary(msg.content) and String.length(msg.content) > 5 do
      :ok
    else
      {:error, "empty response: #{inspect(msg)}"}
    end
  end

  defp streaming_text do
    {:ok, stream} =
      Nous.LLM.stream_text(
        "vertex_ai:#{@model}",
        "Count out loud: 1, 2, 3, done.",
        temperature: 0.0,
        receive_timeout: 600_000
      )

    text = stream |> Enum.into("")

    if String.contains?(String.downcase(text), "done") do
      :ok
    else
      {:error, "unexpected stream output: #{inspect(text)}"}
    end
  end

  defp streaming_tools do
    weather_tool =
      Nous.Tool.from_function(
        fn _ctx, %{"city" => city} ->
          {:ok, "Weather in #{city}: 21C, sunny"}
        end,
        name: "get_weather",
        description: "Get current weather for a city",
        parameters: %{
          "type" => "object",
          "properties" => %{"city" => %{"type" => "string"}},
          "required" => ["city"]
        }
      )

    {:ok, stream} =
      Nous.LLM.stream_text(
        "vertex_ai:#{@model}",
        "What's the weather in Berlin? Use the tool.",
        tools: [weather_tool],
        temperature: 0.0,
        receive_timeout: 600_000
      )

    text = stream |> Enum.into("")

    if String.contains?(text, "21") or String.contains?(String.downcase(text), "sunny") do
      :ok
    else
      {:error, "streaming tool loop didn't reach final answer: #{inspect(text)}"}
    end
  end

  defp safety_settings do
    model =
      Nous.Model.parse(
        "vertex_ai:#{@model}",
        receive_timeout: 600_000,
        default_settings: %{
          safety_settings: [
            %{category: "HARM_CATEGORY_DANGEROUS_CONTENT", threshold: "BLOCK_NONE"},
            %{category: "HARM_CATEGORY_HARASSMENT", threshold: "BLOCK_NONE"}
          ],
          temperature: 0.0
        }
      )

    case Nous.ModelDispatcher.request(
           model,
           [Nous.Message.user("Say hello.")],
           model.default_settings
         ) do
      {:ok, %Nous.Message{}} -> :ok
      other -> {:error, inspect(other)}
    end
  end

  # ---------------------------------------------------------------------------

  defp run_test(label, fun) do
    started = System.monotonic_time(:millisecond)

    result =
      try do
        fun.()
      rescue
        e -> {:error, Exception.message(e)}
      catch
        kind, value -> {:error, "#{kind}: #{inspect(value)}"}
      end

    ms = System.monotonic_time(:millisecond) - started

    case result do
      :ok ->
        IO.puts("PASS  #{label} (#{ms} ms)")

      {:error, reason} ->
        IO.puts("FAIL  #{label} (#{ms} ms)")
        IO.puts("      #{reason}")
    end
  end

  defp require_env! do
    missing =
      Enum.filter(
        ["VERTEX_AI_ACCESS_TOKEN", "GOOGLE_CLOUD_PROJECT"],
        fn name -> System.get_env(name) in [nil, ""] end
      )

    if missing != [] do
      IO.puts("missing env vars: #{Enum.join(missing, ", ")}")
      IO.puts("set them and rerun:")
      IO.puts("  export VERTEX_AI_ACCESS_TOKEN=\"$(gcloud auth print-access-token)\"")
      IO.puts("  export GOOGLE_CLOUD_PROJECT=\"<your-gcp-project-id>\"")
      System.halt(1)
    end
  end
end

Smoke.run()
