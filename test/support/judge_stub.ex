defmodule Nous.Eval.JudgeStub do
  @moduledoc false
  # A scripted model dispatcher for LLM-judge tests, installed with
  # `Nous.ModelDispatcher.put_dispatcher/1` (process-scoped, so tests stay
  # `async: true`). The script lives in the installing process's dictionary
  # and is found from task processes through `$callers`, so judge calls the
  # scoring or calibration code fans out still hit it.
  #
  # Every request is reported to the installing process as
  # `{:judge_request, index, messages, settings}`: tests assert on what the
  # judge model actually received.

  alias Nous.{Message, Usage}

  @key :"$nous_judge_stub"

  @doc """
  Installs the stub. `script` is a list of responses used in request order
  (the last one repeats) or a function of `%{index, system, user}`. A
  response is the model's text, `{:error, reason}`, or `{:raise, message}`.
  """
  def install(script) do
    Process.put(@key, %{owner: self(), script: script, counter: :counters.new(1, [])})
    Nous.ModelDispatcher.put_dispatcher(__MODULE__)
  end

  @doc "A verdict object as the judge model would return it."
  def verdict(label, critique \\ "Looks right."),
    do: JSON.encode!(%{"verdict" => label, "critique" => critique})

  def request(_model, messages, settings) do
    %{owner: owner, script: script, counter: counter} = Nous.CallerLookup.lookup(@key, &is_map/1)
    :counters.add(counter, 1, 1)
    index = :counters.get(counter, 1) - 1
    send(owner, {:judge_request, index, messages, settings})

    request = %{index: index, system: system_prompt(messages), user: user_prompt(messages)}

    case pick(script, request) do
      {:error, _} = error -> error
      {:raise, message} -> raise message
      text when is_binary(text) -> {:ok, reply(text)}
    end
  end

  def request_stream(_model, _messages, _settings), do: {:ok, []}
  def count_tokens(_messages), do: 0

  defp pick(fun, request) when is_function(fun, 1), do: fun.(request)
  defp pick(list, %{index: index}) when is_list(list), do: Enum.at(list, index, List.last(list))

  defp reply(text) do
    Message.from_legacy(%{
      parts: [{:text, text}],
      usage: %Usage{input_tokens: 100, output_tokens: 20, total_tokens: 120, requests: 1},
      model_name: "judge-model",
      timestamp: DateTime.utc_now()
    })
  end

  @doc "The system prompt text of a request."
  def system_prompt(messages) do
    Enum.find_value(messages, "", fn
      %Message{role: :system} = m -> Message.extract_text(m)
      _ -> nil
    end)
  end

  @doc "The first user message text of a request (the judge prompt)."
  def user_prompt(messages) do
    Enum.find_value(messages, "", fn
      %Message{role: :user} = m -> Message.extract_text(m)
      _ -> nil
    end)
  end

  @doc "The fence boundary used in a judge prompt."
  def boundary(prompt) do
    [_, boundary] = Regex.run(~r/<<<(INPUT_[A-Za-z0-9_-]+) /, prompt)
    boundary
  end

  @doc "The text inside the fence named `name` of a judge prompt, or nil."
  def fenced(prompt, name) do
    boundary = boundary(prompt)
    open = "<<<#{boundary} #{name}\n"
    close = "\n#{boundary} #{name}>>>"

    with [_, rest] <- String.split(prompt, open, parts: 2),
         [inside, _] <- String.split(rest, close, parts: 2) do
      inside
    else
      _ -> nil
    end
  end
end
