defmodule Nous.Tools.PathGuard do
  @moduledoc """
  Path-traversal & symlink-escape protection for filesystem tools.

  LLMs control the path argument to file tools. Without a guard, a single
  prompt-injected document can read `~/.aws/credentials`, write to
  `~/.ssh/authorized_keys`, or globsweep `/etc/`. This module enforces
  that every path resolves *inside* a configured workspace root.

  ## Configuring the workspace root

  Pass it via the agent's `ctx.deps`:

      Agent.new("openai:gpt-4",
        tools: [Nous.Tools.FileRead, Nous.Tools.FileWrite],
        deps: %{workspace_root: "/srv/agent_workspace/\#{user_id}"}
      )

  When `workspace_root` is absent from the deps, the guard defaults to the
  current working directory (`File.cwd!/0`). For multi-tenant deployments you
  almost certainly want to set it explicitly per session. A *present* but
  unusable value (anything other than a non-empty string) is refused rather
  than defaulted — a misconfigured jail denies every path instead of silently
  widening to the cwd.

  Sub-agents never widen the jail: `Nous.Plugins.SubAgent` clamps a child's
  root to its parent's via `effective_root/1`, independently of
  `:sub_agent_shared_deps`.

  ## What's blocked

  - Paths that, after `Path.expand/1`, escape the configured root
  - Symlinks whose target escapes the root
  - Any path containing a NUL byte (defense-in-depth)

  ## What's not

  Only the tools that call `validate/2` are confined — the five file tools.
  `Nous.Tools.Bash` runs a command line the guard never sees, so an agent
  holding both `FileRead` and `Bash` has a jail on one and none on the other.
  Grant `Bash` accordingly.

  ## Returned path & TOCTOU

  On success `validate/2` returns the **canonical, symlink-resolved** path
  (every existing component dereferenced), not the raw argument. Callers MUST
  open *that* path so they operate on the same inode the guard validated,
  rather than re-traversing an attacker-swappable symlink in the original
  argument.

  This narrows but does not fully eliminate a time-of-check/time-of-use race:
  between `validate/2` returning and the caller opening the path, a writer with
  access to the workspace could still swap a now-resolved component for a
  symlink. Eliminating that window entirely requires `openat`/`O_NOFOLLOW`,
  which the Erlang `:file` API does not expose. The practical mitigation is to
  give each session a dedicated `workspace_root` that no other writer owns.
  """

  @doc """
  Resolve `path` against the configured workspace root and return either
  `{:ok, canonical_path}` or `{:error, reason}` where `reason` is a
  human-readable string suitable to surface back to the LLM.

  `canonical_path` is the symlink-resolved absolute path; callers should open
  it directly (see the "Returned path & TOCTOU" note in the moduledoc).
  """
  @spec validate(String.t(), Nous.RunContext.t() | map() | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  def validate(path, ctx \\ nil)

  def validate(path, _ctx) when not is_binary(path) do
    {:error, "file_path must be a string"}
  end

  def validate(path, ctx) do
    with :ok <- reject_nul(path),
         {:ok, root} <- effective_root(ctx),
         {:ok, expanded} <- expand_against(path, root),
         :ok <- ensure_within(expanded, root),
         {:ok, real_path} <- ensure_no_symlink_escape(expanded, root) do
      {:ok, real_path}
    end
  end

  # ---------------------------------------------------------------------------

  defp reject_nul(path) do
    if String.contains?(path, "\x00") do
      {:error, "file_path contains a NUL byte"}
    else
      :ok
    end
  end

  @doc """
  Return the workspace root that confines `ctx`, or an error when the
  configured root is unusable.

  This is the resolution `validate/2` performs internally: an absent
  `:workspace_root` yields the current working directory, a non-empty string is
  expanded to an absolute path, and anything else is refused. Callers that need
  to *derive* a confinement boundary rather than check a path — `SubAgent`
  clamps a sub-agent's root to its parent's — must come through here so there
  is exactly one definition of the jail.
  """
  @spec effective_root(Nous.RunContext.t() | map() | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  def effective_root(ctx) do
    # Map.fetch, not Map.get: an ABSENT key is the documented "default to cwd"
    # case, while a key explicitly set to nil is a misconfiguration. Collapsing
    # the two would make every unusable root fall back to the cwd — the exact
    # silent widening this guard exists to prevent.
    case Map.fetch(deps_of(ctx), :workspace_root) do
      :error ->
        {:ok, Path.expand(File.cwd!())}

      {:ok, root} when is_binary(root) and root != "" ->
        {:ok, Path.expand(root)}

      {:ok, other} ->
        {:error, "workspace root #{inspect(other)} is not a non-empty string; refusing to access"}
    end
  rescue
    File.Error -> {:error, "workspace root is unavailable"}
  end

  defp deps_of(%{deps: deps}) when is_map(deps), do: deps
  defp deps_of(%{deps: _}), do: %{}
  defp deps_of(%{} = deps), do: deps
  defp deps_of(_), do: %{}

  defp expand_against(path, root) do
    expanded =
      cond do
        # Absolute path - expand normalises any embedded `..`/`.`.
        Path.type(path) == :absolute -> Path.expand(path)
        # Relative path - resolve relative to the workspace root.
        true -> Path.expand(path, root)
      end

    {:ok, expanded}
  end

  defp ensure_within(expanded, root) do
    # `expanded` may already be symlink-resolved (e.g. a path returned by a
    # previous validate/2 call, as file_glob/file_grep re-validate wildcard
    # results). Such a path won't lexically match an unresolved root, so accept
    # it if it is within either the raw OR the resolved root before rejecting.
    if within_root?(expanded, root) or within_root?(expanded, resolved_root(root)) do
      :ok
    else
      {:error,
       "path #{inspect(expanded)} escapes the workspace root #{inspect(root)}; refusing to access"}
    end
  end

  defp resolved_root(root) do
    case resolve_real(root) do
      {:ok, real_root} -> real_root
      _ -> root
    end
  end

  @doc false
  # Containment for an already-expanded (or already-canonical) path against an
  # already-expanded root. `SubAgent` needs the same test to decide whether a
  # child's requested root is inside its parent's, and two copies of a jail
  # boundary is how one of them ends up subtly different.
  #
  # The trailing slash is load-bearing: without it `"/srv/ws/t1evil"` counts as
  # inside `"/srv/ws/t1"`. But a root of `"/"` would make the prefix `"//"`, which
  # no `Path.expand`-normalised path starts with — so an operator spelling "no
  # jail" as `workspace_root: "/"` got a jail that denied every path, for the
  # parent and every sub-agent alike.
  @spec within_root?(String.t(), String.t()) :: boolean()
  def within_root?(path, root) do
    path == root or String.starts_with?(path, root_prefix(root))
  end

  defp root_prefix("/"), do: "/"
  defp root_prefix(root), do: root <> "/"

  defp ensure_no_symlink_escape(expanded, root) do
    # Resolve symlinks across EVERY component (not just the leaf), then compare
    # the canonical path against the canonical root. The previous version only
    # lstat'd the final component, so an *intermediate* directory symlink
    # (e.g. `link -> /etc`, accessed as `link/passwd`) escaped the jail because
    # Path.expand never resolves symlinks. Resolving the root too makes the
    # comparison robust to symlinked roots (e.g. macOS `/tmp -> /private/tmp`).
    with {:ok, real_root} <- resolve_real(root),
         {:ok, real_path} <- resolve_real(expanded) do
      if within_root?(real_path, real_root) do
        {:ok, real_path}
      else
        {:error,
         "path #{inspect(expanded)} resolves outside the workspace root via a symlink; refusing to follow"}
      end
    else
      {:error, :symlink_loop} ->
        {:error, "path #{inspect(expanded)} contains a symlink loop; refusing"}
    end
  end

  @doc false
  # The canonical form of a *root* — used by `Nous.Plugins.SubAgent` to decide
  # whether a requested sub-agent root is inside its parent's. A lexical prefix
  # test admits `parent/link` where `link -> /etc`, and the child's own guard
  # then canonicalises both sides and agrees with itself, so the child's jail
  # ends up strictly WIDER than its parent's. Admission must be decided on the
  # same canonical form the guard enforces.
  @spec canonical_root(String.t()) :: {:ok, String.t()} | {:error, :symlink_loop}
  def canonical_root(path) when is_binary(path), do: resolve_real(path)

  # Best-effort realpath: resolves symlinks for the portion of the path that
  # exists, component by component. Non-existent trailing components cannot be
  # symlinks, so they are appended verbatim (this lets FileWrite create new
  # files/dirs while still catching an escaping symlink anywhere above them).
  #
  # The bound counts symlink FOLLOWS, not components: counting every component
  # capped usable workspace depth at ~40 path segments (a nested monorepo or
  # `node_modules` tree crosses that routinely) and blamed a "symlink loop" that
  # did not exist. Termination still holds — `rest` shrinks on every non-follow,
  # and every follow increments toward the bound.
  @max_symlink_depth 40

  defp resolve_real(path) do
    resolve_components(Path.split(Path.expand(path)), "/", 0)
  end

  defp resolve_components(_remaining, _resolved, follows) when follows > @max_symlink_depth do
    {:error, :symlink_loop}
  end

  defp resolve_components([], resolved, _follows), do: {:ok, resolved}

  defp resolve_components(["/" | rest], resolved, follows),
    do: resolve_components(rest, resolved, follows)

  defp resolve_components([comp | rest], resolved, follows) do
    candidate = Path.join(resolved, comp)

    case File.read_link(candidate) do
      {:ok, target} ->
        # Resolve the link target against the directory holding the link
        # (absolute targets ignore the base), then continue resolving the
        # remaining components from the resolved target.
        resolved_target = Path.expand(target, resolved)
        resolve_components(Path.split(resolved_target) ++ rest, "/", follows + 1)

      _not_a_symlink ->
        resolve_components(rest, candidate, follows)
    end
  end
end
