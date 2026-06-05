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

  When `workspace_root` is unset, the guard defaults to the current
  working directory (`File.cwd!/0`). For multi-tenant deployments you
  almost certainly want to set it explicitly per session.

  ## What's blocked

  - Paths that, after `Path.expand/1`, escape the configured root
  - Symlinks whose target escapes the root
  - Any path containing a NUL byte (defense-in-depth)

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
         {:ok, root} <- workspace_root(ctx),
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

  defp workspace_root(ctx) do
    deps =
      case ctx do
        %{deps: deps} -> deps
        %{} = deps -> deps
        _ -> %{}
      end

    root =
      case Map.get(deps || %{}, :workspace_root) do
        nil -> File.cwd!()
        root when is_binary(root) -> root
      end

    {:ok, Path.expand(root)}
  rescue
    File.Error -> {:error, "workspace root is unavailable"}
  end

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
    if within?(expanded, root) or within?(expanded, resolved_root(root)) do
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

  defp within?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end

  defp ensure_no_symlink_escape(expanded, root) do
    # Resolve symlinks across EVERY component (not just the leaf), then compare
    # the canonical path against the canonical root. The previous version only
    # lstat'd the final component, so an *intermediate* directory symlink
    # (e.g. `link -> /etc`, accessed as `link/passwd`) escaped the jail because
    # Path.expand never resolves symlinks. Resolving the root too makes the
    # comparison robust to symlinked roots (e.g. macOS `/tmp -> /private/tmp`).
    with {:ok, real_root} <- resolve_real(root),
         {:ok, real_path} <- resolve_real(expanded) do
      if real_path == real_root or String.starts_with?(real_path, real_root <> "/") do
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

  # Best-effort realpath: resolves symlinks for the portion of the path that
  # exists, component by component. Non-existent trailing components cannot be
  # symlinks, so they are appended verbatim (this lets FileWrite create new
  # files/dirs while still catching an escaping symlink anywhere above them).
  @max_symlink_depth 40

  defp resolve_real(path) do
    resolve_components(Path.split(Path.expand(path)), "/", 0)
  end

  defp resolve_components(_remaining, _resolved, depth) when depth > @max_symlink_depth do
    {:error, :symlink_loop}
  end

  defp resolve_components([], resolved, _depth), do: {:ok, resolved}

  defp resolve_components(["/" | rest], resolved, depth),
    do: resolve_components(rest, resolved, depth)

  defp resolve_components([comp | rest], resolved, depth) do
    candidate = Path.join(resolved, comp)

    case File.read_link(candidate) do
      {:ok, target} ->
        # Resolve the link target against the directory holding the link
        # (absolute targets ignore the base), then continue resolving the
        # remaining components from the resolved target.
        resolved_target = Path.expand(target, resolved)
        resolve_components(Path.split(resolved_target) ++ rest, "/", depth + 1)

      _not_a_symlink ->
        resolve_components(rest, candidate, depth + 1)
    end
  end
end
