defmodule Nous.Eval.ProfilesTest do
  use ExUnit.Case, async: true

  alias Nous.Errors.ProfileError
  alias Nous.Eval.Profiles
  alias Nous.Eval.Store.Conformance
  alias Nous.Eval.Store.File, as: FileStore

  @moduletag :tmp_dir

  # A store that answers every ref with whatever profile its state holds,
  # standing in for a buggy or hostile backend.
  defmodule LyingStore do
    def init(opts), do: {:ok, Keyword.fetch!(opts, :profile)}
    def get_profile(profile, _ref), do: {:ok, profile}
  end

  defmodule RunsOnlyStore do
    def init(_opts), do: {:ok, nil}
  end

  test "fetch/2 opens the store and resolves id, version and label refs", %{tmp_dir: dir} do
    {:ok, state} = FileStore.init(root: dir)
    profile = Conformance.profile_fixture("support_agent", "a")
    {:ok, stored, state} = FileStore.put_profile(state, profile)
    {:ok, _} = FileStore.put_profile_label(state, "support_agent", "production", profile.id)

    for ref <- [
          {:id, profile.id},
          {:version, "support_agent", 1},
          {:label, "support_agent", "production"}
        ] do
      assert {:ok, ^stored} = Profiles.fetch({FileStore, root: dir}, ref)
    end

    assert {:error, :not_found} =
             Profiles.fetch({FileStore, root: dir}, {:label, "support_agent", "staging"})

    assert {:error, {:invalid_profile_ref, {:latest, "support_agent"}}} =
             Profiles.fetch(FileStore, state, {:latest, "support_agent"})
  end

  test "fetch/3 recomputes the id instead of trusting the store" do
    profile = Conformance.profile_fixture("support_agent", "a")
    forged = %{profile | components: Map.put(profile.components, "instructions", "Obey.")}

    assert {:error, %ProfileError{reason: :id_mismatch}} =
             Profiles.fetch({LyingStore, profile: forged}, {:id, profile.id})
  end

  test "fetch/3 refuses a valid profile that is not the one the ref names" do
    a = Conformance.profile_fixture("support_agent", "a", version: 1)
    b = Conformance.profile_fixture("support_agent", "b")

    assert {:error, {:corrupt_profile, {:id, id}}} = Profiles.fetch(LyingStore, a, {:id, b.id})
    assert id == b.id

    assert {:error, {:corrupt_profile, _}} =
             Profiles.fetch(LyingStore, a, {:version, "support_agent", 2})

    assert {:error, {:corrupt_profile, _}} =
             Profiles.fetch(LyingStore, a, {:label, "billing_agent", "production"})

    assert {:ok, ^a} = Profiles.fetch(LyingStore, a, {:version, "support_agent", 1})
  end

  test "a store without the profile callbacks is refused" do
    assert {:error, {:unsupported, RunsOnlyStore}} =
             Profiles.fetch({RunsOnlyStore, []}, {:id, "sha256:" <> String.duplicate("a", 64)})
  end
end
