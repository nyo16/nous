defmodule Nous.Permissions.Policy do
  @moduledoc """
  Permission policy controlling tool access.

  Defines which tools are denied, which require approval,
  and the overall permission mode.

  ## Modes

    * `:default` — read/search tools are open, write/execute tools require approval
    * `:permissive` — all tools are open, none require approval
    * `:strict` — all tools require approval; at the filter layer, ONLY tools
      in `:allow_names` / `:allow_prefixes` are exposed (deny-by-default).

  ## Examples

      # Custom policy that blocks bash and requires approval for write tools
      %Nous.Permissions.Policy{
        deny_names: MapSet.new(["bash"]),
        approval_required: MapSet.new(["file_write", "file_edit"]),
        mode: :default
      }

      # Strict + explicit allowlist
      %Nous.Permissions.Policy{
        mode: :strict,
        allow_names: MapSet.new(["file_read", "search_web"])
      }

  """

  defstruct deny_names: MapSet.new(),
            deny_prefixes: [],
            allow_names: MapSet.new(),
            allow_prefixes: [],
            approval_required: MapSet.new(),
            allow_unattended_execute: false,
            mode: :default

  @type mode :: :default | :permissive | :strict

  @type t :: %__MODULE__{
          deny_names: MapSet.t(),
          deny_prefixes: [String.t()],
          allow_names: MapSet.t(),
          allow_prefixes: [String.t()],
          approval_required: MapSet.t(),
          allow_unattended_execute: boolean(),
          mode: mode()
        }

  @mode_rank %{strict: 2, default: 1, permissive: 0}

  @doc """
  Combine two policies so the result is at least as strict as both.

  Used when execution policy must inherit across delegation (e.g.
  `Nous.Plugins.SubAgent`): the parent's policy always applies, and a
  sub-agent template may only *narrow* it, never widen it. `nil` means
  "no policy" and yields the other argument unchanged.

  Combination rules:

    * `mode` — the stricter of the two (`:strict` > `:default` > `:permissive`)
    * `deny_names` / `deny_prefixes` / `approval_required` — union
    * `allow_unattended_execute` — logical AND
    * allowlists — an allowlist means deny-by-default (see
      `Nous.Permissions.blocked?/2`), and a `:strict` policy's allowlist is its
      *entire* grant (empty = allow nothing, not "no opinion"). If only one
      side constrains the allow set, its list stands; if both do, the result
      allows only what BOTH sides allow. When that combination allows nothing,
      the result is pinned to `mode: :strict` with an empty allowlist —
      `blocked?/2` reads that as deny-everything, whereas an empty allowlist on
      `:default`/`:permissive` would read as "no allowlist" and fail open.
  """
  @spec strictest(t() | nil, t() | nil) :: t() | nil
  def strictest(nil, nil), do: nil
  def strictest(%__MODULE__{} = a, nil), do: a
  def strictest(nil, %__MODULE__{} = b), do: b

  def strictest(%__MODULE__{} = a, %__MODULE__{} = b) do
    {allow_names, allow_prefixes, deny_all?} = combine_allowlists(a, b)

    mode =
      if deny_all? do
        # The only representation of "allow nothing" blocked?/2 honors.
        :strict
      else
        strictest_mode(a.mode, b.mode)
      end

    %__MODULE__{
      mode: mode,
      deny_names: MapSet.union(a.deny_names, b.deny_names),
      deny_prefixes: Enum.uniq(a.deny_prefixes ++ b.deny_prefixes),
      approval_required: MapSet.union(a.approval_required, b.approval_required),
      allow_unattended_execute: a.allow_unattended_execute and b.allow_unattended_execute,
      allow_names: allow_names,
      allow_prefixes: allow_prefixes
    }
  end

  defp strictest_mode(a, b) do
    if Map.get(@mode_rank, a, 3) >= Map.get(@mode_rank, b, 3), do: a, else: b
  end

  # A policy constrains the allow set when it carries an explicit allowlist OR
  # is :strict — strict-with-empty-allowlist means deny-everything
  # (Nous.Permissions.blocked?/2), so treating it as "no opinion" would let the
  # other side's allowlist stand and WIDEN a deny-all policy.
  defp combine_allowlists(a, b) do
    case {constrains_allows?(a), constrains_allows?(b)} do
      {false, false} ->
        {MapSet.new(), [], false}

      {true, false} ->
        {a.allow_names, a.allow_prefixes, deny_all?(a)}

      {false, true} ->
        {b.allow_names, b.allow_prefixes, deny_all?(b)}

      {true, true} ->
        {names, prefixes} = intersect_allowlists(a, b)
        # Disjoint (or deny-all-vs-anything) constrained sides allow NOTHING.
        # Without the deny_all flag the empty result would read as "no
        # allowlist" and evaporate deny-by-default entirely.
        {names, prefixes, MapSet.size(names) == 0 and prefixes == []}
    end
  end

  defp constrains_allows?(%__MODULE__{} = p), do: has_allowlist?(p) or p.mode == :strict

  defp deny_all?(%__MODULE__{} = p), do: p.mode == :strict and not has_allowlist?(p)

  defp has_allowlist?(%__MODULE__{allow_names: names, allow_prefixes: prefixes}) do
    MapSet.size(names) > 0 or prefixes != []
  end

  # Deny-by-default on both sides: a name survives only if the OTHER side's
  # allowlist also admits it; a prefix survives as the longer of any pair
  # where one prefix extends the other (everything it matches, both match).
  defp intersect_allowlists(a, b) do
    names =
      MapSet.union(
        MapSet.filter(a.allow_names, &admits?(b, &1)),
        MapSet.filter(b.allow_names, &admits?(a, &1))
      )

    prefixes =
      for pa <- a.allow_prefixes,
          pb <- b.allow_prefixes,
          p = prefix_intersection(pa, pb),
          p != nil,
          uniq: true,
          do: p

    {names, prefixes}
  end

  defp admits?(%__MODULE__{allow_names: names, allow_prefixes: prefixes}, name) do
    MapSet.member?(names, name) or
      Enum.any?(prefixes, &String.starts_with?(name, String.downcase(&1)))
  end

  defp prefix_intersection(pa, pb) do
    cond do
      String.starts_with?(pa, pb) -> pa
      String.starts_with?(pb, pa) -> pb
      true -> nil
    end
  end
end
