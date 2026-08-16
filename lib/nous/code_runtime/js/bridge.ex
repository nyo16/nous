defmodule Nous.CodeRuntime.JS.Bridge do
  @moduledoc false

  # The single Elixir function guest JavaScript may call, and the only route
  # from a program into this repo.
  #
  # It is the whole of tyrex's `:apply` allowlist: `[{__MODULE__, :call, 1}]`.
  # One module, one function, one arity - so the allowlist cannot be widened by
  # a program, and `Enum.count/1` is refused as loudly as `:erlang.halt/0`
  # (measured: "permission_denied: Enum.count/1 is not in the :apply
  # allowlist").
  #
  # ## Why the session is found by pid and not passed in
  #
  # Everything in `payload` came from model-authored JavaScript, so nothing in
  # it can be trusted to say which run is calling. `call/1` instead runs INSIDE
  # tyrex's own runtime process - that is where an allowlisted MFA is invoked -
  # so `self()` is the runtime's pid, which the guest cannot forge or influence.
  # The session registers itself under that pid before evaluating anything, and
  # the lookup is the authorization: an unregistered runtime gets no session and
  # therefore no tools.
  #
  # ## Why nothing here blocks
  #
  # An allowlisted MFA runs inline on the runtime's message loop, so while it
  # runs the runtime cannot process its own deadline message. tyrex documents
  # this and does not intend to change it (authorization deliberately lives
  # outside the isolate's blast radius). Two things follow, and both are load
  # bearing:
  #
  #   * a bridge call that waited for a tool would suspend the eval deadline for
  #     as long as the tool ran - measured upstream at 6s of bridge time under a
  #     500ms deadline - and would serialise every sub-call behind it, which
  #     would quietly reduce the scheduler's parallelism to one.
  #   * so tool work happens in the session's own processes, and every operation
  #     here is a bounded message round trip: submit hands off and returns a
  #     ticket, poll answers with whatever is already finished, log appends.
  #     The guest waits with a JS timer instead, which `setTimeout` supports
  #     while awaiting a reply (measured: 20 rounds of bridge + 5ms sleep in
  #     141ms).

  alias Nous.CodeRuntime.JS.Session

  @registry Nous.CodeRuntime.JS.Registry

  # Long enough that a busy session under a full parallel batch still answers,
  # short enough that a wedged session cannot hold the runtime's message loop
  # for the rest of the run. A timeout here is a bug in us, not in the program,
  # so it surfaces as a substrate error rather than a tool error.
  @session_timeout 5_000

  @doc false
  @spec allowlist() :: [{module(), atom(), arity()}]
  def allowlist, do: [{__MODULE__, :call, 1}]

  @doc false
  @spec registry() :: atom()
  def registry, do: @registry

  @doc false
  @spec call(map()) :: map()
  def call(payload) when is_map(payload) do
    case Registry.lookup(@registry, self()) do
      [{session, _}] -> dispatch(session, payload)
      [] -> %{"error" => %{"kind" => "substrate", "message" => "no run is bound to this runtime"}}
    end
  end

  # A non-map payload cannot come from the prelude, so it is a program calling
  # the bridge through some route we did not build. Answer in the same shape a
  # program can read rather than raising: an exception here would surface as a
  # rejected promise with tyrex's own wording, which tells the model nothing
  # about what it did wrong.
  def call(_payload) do
    %{"error" => %{"kind" => "contract", "message" => "bridge payload must be an object"}}
  end

  defp dispatch(session, %{"op" => "submit"} = payload) do
    tool = Map.get(payload, "tool")
    args = Map.get(payload, "args", %{})

    if is_binary(tool) do
      Session.submit(session, tool, args, @session_timeout)
    else
      %{"error" => %{"kind" => "contract", "message" => "submit requires a tool name"}}
    end
  end

  defp dispatch(session, %{"op" => "poll"} = payload) do
    tickets = Map.get(payload, "tickets", [])
    Session.poll(session, List.wrap(tickets), @session_timeout)
  end

  defp dispatch(session, %{"op" => "log"} = payload) do
    Session.log(
      session,
      Map.get(payload, "stream", "stdout"),
      Map.get(payload, "line", ""),
      @session_timeout
    )
  end

  defp dispatch(_session, payload) do
    %{
      "error" => %{
        "kind" => "contract",
        "message" => "unknown bridge op: #{inspect(Map.get(payload, "op"))}"
      }
    }
  end
end
