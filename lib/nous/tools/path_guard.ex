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
  """

  @doc """
  Resolve `path` against the configured workspace root and return either
  `{:ok, absolute_path}` or `{:error, reason}` where `reason` is a
  human-readable string suitable to surface back to the LLM.
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
         :ok <- ensure_no_symlink_escape(expanded, root) do
      {:ok, expanded}
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
    if expanded == root or String.starts_with?(expanded, root <> "/") do
      :ok
    else
      {:error,
       "path #{inspect(expanded)} escapes the workspace root #{inspect(root)}; refusing to access"}
    end
  end

  defp ensure_no_symlink_escape(expanded, root) do
    # Walk every component of the expanded path; if any is a symlink whose
    # *target* escapes the root, refuse. We use lstat to NOT follow the
    # link on the final component, then read_link to inspect the target.
    case File.lstat(expanded) do
      {:ok, %{type: :symlink}} ->
        case File.read_link(expanded) do
          {:ok, target} ->
            target_abs = Path.expand(target, Path.dirname(expanded))

            if String.starts_with?(target_abs, root <> "/") or target_abs == root do
              :ok
            else
              {:error,
               "symlink #{inspect(expanded)} points outside workspace root; refusing to follow"}
            end

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end
end
