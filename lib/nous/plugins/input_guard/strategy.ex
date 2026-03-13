defmodule Nous.Plugins.InputGuard.Strategy do
  @moduledoc """
  Behaviour for input guard detection strategies.

  Implement this behaviour to create custom strategies for detecting
  malicious or unwanted input. Each strategy receives the user input text,
  its own configuration, and the full agent context.

  ## Creating Your Own Strategy

  Here's a complete example of a custom blocklist strategy:

      defmodule MyApp.InputGuard.Blocklist do
        @behaviour Nous.Plugins.InputGuard.Strategy
        alias Nous.Plugins.InputGuard.Result

        @impl true
        def check(input, config, _ctx) do
          blocklist = Keyword.get(config, :words, [])
          downcased = String.downcase(input)

          case Enum.find(blocklist, &String.contains?(downcased, &1)) do
            nil ->
              {:ok, %Result{severity: :safe}}

            word ->
              {:ok, %Result{
                severity: :blocked,
                reason: "Blocklisted word: \#{word}",
                strategy: __MODULE__
              }}
          end
        end
      end

  Then use it in your agent configuration:

      agent = Nous.new("openai:gpt-4",
        plugins: [Nous.Plugins.InputGuard]
      )

      {:ok, result} = Nous.run(agent, "Hello",
        deps: %{
          input_guard_config: %{
            strategies: [
              {MyApp.InputGuard.Blocklist, words: ["hack", "exploit"]}
            ]
          }
        }
      )

  """

  alias Nous.Agent.Context
  alias Nous.Plugins.InputGuard.Result

  @doc """
  Check input text for malicious content.

  Returns `{:ok, result}` with a `Result` struct indicating the severity,
  or `{:error, reason}` if the check itself failed.

  ## Parameters

    * `input` — The user's input text to check
    * `config` — Strategy-specific configuration from the `{Module, opts}` tuple
    * `ctx` — The full agent context for access to message history, deps, etc.

  """
  @callback check(input :: String.t(), config :: keyword(), ctx :: Context.t()) ::
              {:ok, Result.t()} | {:error, term()}
end
