defmodule Nous.Tools.Env do
  @moduledoc """
  Scrubbed environment for tool subprocesses.

  Tools that spawn OS processes (`bash`, ripgrep in `file_grep`) must not
  inherit the BEAM's environment: it routinely holds API keys, OAuth tokens,
  and vault credentials, and an LLM is one `printenv` away from leaking them.
  Shell-loader hooks (LD_PRELOAD, DYLD_INSERT_LIBRARIES) are dropped for the
  same reason.

  Every subprocess-spawning tool must use `scrubbed/0` so the allowlist has
  exactly one definition.
  """

  # Whitelist of env vars safe to forward to subprocesses. Everything else
  # is dropped.
  @allowlist ~w(PATH HOME LANG LC_ALL TZ USER SHELL TERM)

  @doc """
  The environment to pass to tool subprocesses: allowlisted variables that
  are currently set, as `{name, value}` tuples.
  """
  @spec scrubbed() :: [{String.t(), String.t()}]
  def scrubbed do
    @allowlist
    |> Enum.map(fn name -> {name, System.get_env(name)} end)
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
  end
end
