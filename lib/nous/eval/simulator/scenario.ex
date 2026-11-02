defmodule Nous.Eval.Simulator.Scenario do
  @moduledoc """
  What the simulated user of one `nous.sim_case/1` case is told: the
  `input` of a simulated case (`Nous.Eval.Case`).

  Built by the case loader (`Nous.Eval.Simulator.sim_case/1`, or a
  `nous.sim_case/1` dataset file), never by hand: the loader validates every
  field.

    * `:kind` - `:task` (a user with a goal; the episode is scored on what
      the agent achieved) or `:adversarial` (an attacker with an objective;
      the episode is scored on whether the agent was breached)
    * `:max_turns` - the most messages the simulated user may send (1..50)
    * `:fixture` - a string the task's `c:Nous.Eval.episode_setup/1` reads to
      build the episode's environment, or `nil`
    * `:persona` - who the user is and how they behave
    * `:goal` - what the user wants (required for `:task`)
    * `:known` - facts the user may disclose when the agent asks for them
      (`%{name => value}`)
    * `:unknown` - things the user does not know and must say so about
    * `:constraints` - rules the user keeps to
    * `:opener` - a fixed first message, sent without calling the simulator
    * `:done_when` - when the user may consider the goal achieved
    * `:attack` - `%{objective: text, strategy: :direct | :crescendo |
      :roleplay | :persuasion}` for `:adversarial` cases, else `nil`

  The case's `expected` is deliberately not part of it: nothing the scorers
  check ever reaches the simulator.
  """

  @type kind :: :task | :adversarial
  @type strategy :: :direct | :crescendo | :roleplay | :persuasion

  @type t :: %__MODULE__{
          kind: kind(),
          max_turns: pos_integer(),
          fixture: String.t() | nil,
          persona: String.t() | nil,
          goal: String.t() | nil,
          known: %{String.t() => String.t() | number() | boolean()},
          unknown: [String.t()],
          constraints: [String.t()],
          opener: String.t() | nil,
          done_when: String.t() | nil,
          attack: %{objective: String.t(), strategy: strategy()} | nil
        }

  @enforce_keys [:kind, :max_turns]
  defstruct [
    :kind,
    :max_turns,
    fixture: nil,
    persona: nil,
    goal: nil,
    known: %{},
    unknown: [],
    constraints: [],
    opener: nil,
    done_when: nil,
    attack: nil
  ]

  @doc false
  # The scenario as JSON-native data, in the file layout: what the dataset
  # content hash covers, so editing any part of it makes a different dataset.
  @spec canonical(t()) :: map()
  def canonical(%__MODULE__{} = s) do
    %{
      "schema" => "nous.sim_case/1",
      "kind" => Atom.to_string(s.kind),
      "max_turns" => s.max_turns,
      "fixture" => s.fixture,
      "user" => %{
        "persona" => s.persona,
        "goal" => s.goal,
        "known" => s.known,
        "unknown" => s.unknown,
        "constraints" => s.constraints,
        "opener" => s.opener,
        "done_when" => s.done_when
      },
      "attack" =>
        s.attack &&
          %{"objective" => s.attack.objective, "strategy" => Atom.to_string(s.attack.strategy)}
    }
  end
end
