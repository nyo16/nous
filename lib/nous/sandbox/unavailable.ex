defmodule Nous.Sandbox.Unavailable do
  @moduledoc """
  The fail-closed default provider: it confines nothing and admits it.

  `Nous.Sandbox.backend/0` selects this module when the platform chain is empty
  (Windows) or when every candidate provider fails to probe clean. Every
  `confine/2` call returns `{:error, {:sandbox_unavailable, mode, nil}}`, so a
  caller that wanted confinement is forced to refuse the spawn rather than
  quietly run the command unfenced. Silent unconfined passthrough is never
  legal; `:danger_full_access` is the explicit, auditable way to ask for none.

  That includes `:danger_full_access` itself. `Nous.Sandbox.confine/2` short
  circuits that mode before any provider is consulted, so a provider seeing it
  means a caller bypassed the dispatch — a bug, not a licence to pass argv
  through untouched.
  """

  @behaviour Nous.Sandbox

  alias Nous.Sandbox
  alias Nous.Sandbox.Policy

  @doc """
  Always refuse: `{:error, {:sandbox_unavailable, policy.mode, nil}}`.

  Uniform across all three modes, on purpose. See the moduledoc.
  """
  @impl Nous.Sandbox
  @spec confine([String.t()], Policy.t()) :: {:error, Sandbox.error()}
  def confine([_ | _], %Policy{} = policy) do
    {:error, {:sandbox_unavailable, policy.mode, nil}}
  end

  @doc """
  Always `{:error, :unusable}` — this provider is a fallback, never the winner
  of a probe.
  """
  @impl Nous.Sandbox
  @spec probe(pos_integer()) :: {:error, :unusable}
  def probe(timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0 do
    {:error, :unusable}
  end
end
