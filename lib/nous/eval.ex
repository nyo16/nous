defmodule Nous.Eval do
  @moduledoc """
  Evaluate agents against datasets, with repeated samples, traces and
  scorers.

  ## The model

    * A **task** is a module that `use`s `Nous.Eval`. It says which agent to
      build, which dataset to run and which scorers judge every case.
    * A **dataset** (`Nous.Eval.Dataset`) is a validated list of
      `Nous.Eval.Case`s, written in Elixir, YAML or JSONL. Every case has a
      stable string id, a split (`train`/`val`/`test`) and a content hash.
    * Each case runs `k` times. Every run is a **sample** (`Nous.Eval.Sample`)
      with the agent's output and the trace of what it did (model calls, tool
      calls, guard verdicts).
    * **Scorers** (`Nous.Eval.Scorer`) turn a sample into scores. Required
      scorers are gates; the others form a weighted soft group compared with
      the case threshold. A scorer that fails to run is an error, never a
      pass.
    * A **run** (`Nous.Eval.Run`) records every sample, the summary
      statistics and a **fingerprint** (`Nous.Eval.Fingerprint`) of the model,
      prompt, tools, guards, data and scorers, so runs are only compared with
      runs of the same configuration.

  ## A task module

      defmodule MyApp.Evals.Refunds do
        use Nous.Eval

        @impl true
        def dataset, do: "evals/refunds.yaml"

        @impl true
        def scorers, do: [{MyApp.Eval.NoToolErrors, []}]

        @impl true
        def setup(_opts), do: {:ok, %{orders: MyApp.Fixtures.orders()}}

        @impl true
        def deps(%{orders: orders}), do: %{orders: orders}

        @impl true
        def agent(%{deps: _deps}) do
          Nous.new("openai:gpt-4o-mini",
            instructions: "You are Acme's support agent.",
            tools: [&MyApp.Tools.search_orders/2, &MyApp.Tools.refund_order/2]
          )
        end
      end

  ## Callbacks

    * `c:agent/1` (required) - builds the agent for one sample. The context
      map carries `:case` (the `Nous.Eval.Case`), `:sample` (0-based sample
      index), `:seed` (the sample's seed or `nil`), `:deps` (the run deps)
      and `:state` (what `c:setup/1` returned)
    * `c:dataset/0` (required) - a `Nous.Eval.Dataset`, a list of cases
      (see `Nous.Eval.Dataset.new/2`) or the path of a YAML/JSONL file
    * `c:scorers/0` - scorers applied to every case, before the case's own
      (default `[]`)
    * `c:setup/1` / `c:teardown/1` - run once around the whole eval run;
      `setup/1` receives the run options and returns `{:ok, state}` or
      `{:error, reason}` (which aborts the run)
    * `c:deps/1` - the deps every sample runs with, from the setup state
      (default `%{}`)

  `use Nous.Eval` sets `@behaviour Nous.Eval` and defines overridable
  defaults for `c:scorers/0`, `c:setup/1`, `c:teardown/1` and `c:deps/1`.
  `Nous.Eval.Task.load/2` validates a task module before it runs.
  """

  alias Nous.Eval.{Case, Dataset}
  alias Nous.Eval.Scorer.Spec

  @typedoc "The context `c:agent/1` receives for one sample."
  @type context :: %{
          required(:case) => Case.t(),
          required(:sample) => non_neg_integer(),
          required(:seed) => integer() | nil,
          required(:deps) => map(),
          required(:state) => term(),
          optional(atom()) => term()
        }

  @typedoc "A scorer as a task or case declares it."
  @type scorer :: module() | {module(), keyword()} | Spec.t()

  @doc "Builds the agent that runs one sample."
  @callback agent(context()) :: Nous.Agent.t()

  @doc "The cases to run: a dataset, a list of cases, or a dataset file path."
  @callback dataset() :: Dataset.t() | [Case.t() | map() | keyword()] | Path.t()

  @doc "Scorers applied to every case."
  @callback scorers() :: [scorer()]

  @doc "Prepares shared state once per eval run."
  @callback setup(opts :: keyword()) :: {:ok, state :: term()} | {:error, term()}

  @doc "Releases what `c:setup/1` acquired; runs even when the run fails."
  @callback teardown(state :: term()) :: term()

  @doc "The deps every sample's agent run receives."
  @callback deps(state :: term()) :: map()

  @optional_callbacks scorers: 0, setup: 1, teardown: 1, deps: 1

  defmacro __using__(_opts) do
    quote do
      @behaviour Nous.Eval

      @impl Nous.Eval
      def scorers, do: []

      @impl Nous.Eval
      def setup(_opts), do: {:ok, nil}

      @impl Nous.Eval
      def teardown(_state), do: :ok

      @impl Nous.Eval
      def deps(_state), do: %{}

      defoverridable scorers: 0, setup: 1, teardown: 1, deps: 1
    end
  end
end
