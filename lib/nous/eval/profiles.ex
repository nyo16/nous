defmodule Nous.Eval.Profiles do
  @moduledoc """
  Loads `Nous.Profile`s from an eval store.

      {:ok, profile} =
        Nous.Eval.Profiles.fetch(
          {Nous.Eval.Store.File, root: "priv/eval"},
          {:label, "support_agent", "production"}
        )

      agent = Nous.new("openai:gpt-4o", instructions: @base, tools: tools, profile: profile)

  `Nous.new/2` takes only a `%Nous.Profile{}`: resolving one from a store is
  I/O with its own failure modes, so it is an explicit step here. A ref is
  `{:id, "sha256:…"}`, `{:version, name, n}` or `{:label, name, label}` (see
  `t:Nous.Eval.Store.profile_ref/0`); a label that was never set is
  `{:error, :not_found}`, never a fallback to another version.

  Whoever can write the store controls the text of every agent that loads
  from it. For production, prefer promoting a profile, exporting it to a
  file (`Nous.Profile.encode/1`), reviewing it in version control and
  loading it with `Nous.Profile.load!/1`.
  """

  alias Nous.Eval.{Codec, Store}
  alias Nous.Profile

  @doc """
  Opens `store` and fetches the profile `ref` names.

  `store` is `{module, init_opts}`: a `Nous.Eval.Store` module and the
  options for its `init/1`. See `fetch/3` for an already open store.
  """
  @spec fetch({module(), keyword()}, Store.profile_ref()) ::
          {:ok, Profile.t()} | {:error, term()}
  def fetch({module, opts}, ref) when is_atom(module) and is_list(opts) do
    with :ok <- check_store(module),
         {:ok, state} <- module.init(opts) do
      fetch(module, state, ref)
    end
  end

  @doc """
  Fetches the profile `ref` names from `module` with its open `state`.

  Fails closed: besides the store's own checks, the profile is re-encoded
  and its content hash recomputed, and it must be what `ref` names (same id,
  same name and version, or the label's name). A mismatch is
  `{:error, %Nous.Errors.ProfileError{reason: :id_mismatch}}` or
  `{:error, {:corrupt_profile, ref}}`. A store without the profile callbacks
  is `{:error, {:unsupported, module}}`.
  """
  @spec fetch(module(), term(), Store.profile_ref()) :: {:ok, Profile.t()} | {:error, term()}
  def fetch(module, state, ref) when is_atom(module) do
    with :ok <- check_store(module),
         :ok <- Store.validate_profile_ref(ref),
         {:ok, %Profile{} = profile} <- module.get_profile(state, ref),
         :ok <- verify(profile),
         :ok <- Store.check_profile_ref(profile, ref) do
      {:ok, profile}
    else
      {:ok, other} -> {:error, {:corrupt_profile, other}}
      {:error, _} = error -> error
    end
  end

  defp check_store(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :get_profile, 2),
      do: :ok,
      else: {:error, {:unsupported, module}}
  end

  # A store hands back whatever it decoded; recompute the id from the text
  # rather than trust it.
  defp verify(%Profile{id: id} = profile) when is_binary(id) do
    with {:ok, map} <- Codec.encode_profile(profile),
         {:ok, %Profile{id: ^id}} <- Profile.from_map(map) do
      :ok
    else
      {:ok, %Profile{}} -> {:error, {:corrupt_profile, {:id, id}}}
      {:error, _} = error -> error
    end
  end

  defp verify(%Profile{}), do: {:error, {:corrupt_profile, :missing_id}}
end
