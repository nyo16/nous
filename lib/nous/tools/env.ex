defmodule Nous.Tools.Env do
  @moduledoc """
  Scrubbed environment for tool subprocesses.

  Tools that spawn OS processes (`bash`, ripgrep in `file_grep`) must not
  inherit the BEAM's environment: it routinely holds API keys, OAuth tokens,
  and vault credentials, and an LLM is one `printenv` away from leaking them.
  Shell-loader hooks (LD_PRELOAD, DYLD_INSERT_LIBRARIES) are dropped for the
  same reason.

  Every subprocess-spawning tool must use this module so the allowlist has
  exactly one definition.

  ## Applying it is not as simple as an `:env` option

  Both spawn mechanisms Nous uses get this wrong in opposite directions, so
  `scrubbed/0` on its own is **not** a control:

    * `NetRunner` has no `:env` option at all. `run/2` forwards unknown options
      to the port layer, which ignores them, and the shepherd `execvp`s — so the
      child inherits the BEAM's entire environment. Passing
      `env: Nous.Tools.Env.scrubbed()` there is silently discarded. Use
      `with_scrubbed_env/1`, which puts the environment in **argv** where it
      cannot be ignored.
    * `System.cmd/3`'s `:env` **merges**. It sets what you list and leaves
      everything else in place, so `OPENAI_API_KEY` survives. Only
      `{name, nil}` removes a variable. Use `scrubbed_overrides/0`.
  """

  # Whitelist of env vars safe to forward to subprocesses. Everything else
  # is dropped.
  @allowlist ~w(PATH HOME LANG LC_ALL TZ USER SHELL TERM)

  @doc """
  The environment to pass to tool subprocesses: allowlisted variables that
  are currently set, as `{name, value}` tuples.

  This is the definition of the allowlist. It is **not** directly usable as an
  `:env` option — see the moduledoc, then `with_scrubbed_env/1` or
  `scrubbed_overrides/0`.
  """
  @spec scrubbed() :: [{String.t(), String.t()}]
  def scrubbed do
    @allowlist
    |> Enum.map(fn name -> {name, System.get_env(name)} end)
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
  end

  @doc """
  Wrap `argv` so it execs with **only** the scrubbed environment.

  Returns `["/usr/bin/env", "-i" | pairs] ++ argv`. `env -i` clears the
  environment before exec'ing, and the `NAME=VALUE` pairs are argv elements —
  no shell parses them, so a value containing quotes, `$`, or spaces is inert.

  This exists because `NetRunner` silently ignores an `:env` option (see the
  moduledoc). Putting the environment in argv is the only way to make it
  effective on that path, and it composes with `Nous.Sandbox.confine/2`, which
  also works by wrapping argv.

  `/usr/bin/env` is addressed absolutely: a bare `env` would resolve through
  `PATH`, which is exactly the substitution this function exists to prevent.

  ## Examples

      iex> Nous.Tools.Env.with_scrubbed_env(["/bin/sh", "-c", "printenv"]) |> Enum.take(2)
      ["/usr/bin/env", "-i"]

  """
  @spec with_scrubbed_env([String.t()]) :: [String.t()]
  def with_scrubbed_env([_ | _] = argv) do
    pairs = Enum.map(scrubbed(), fn {name, value} -> "#{name}=#{value}" end)

    ["/usr/bin/env", "-i"] ++ pairs ++ argv
  end

  @doc """
  An `:env` value for `System.cmd/3` that genuinely leaves only the allowlist.

  Erlang's `{env, _}` merges rather than replaces, so this returns the
  allowlisted pairs **plus** `{name, nil}` for every other variable currently set
  in the BEAM. `nil` is how `System.cmd/3` *removes* a variable (it maps it to
  Erlang's `false` internally); passing `false` here raises, because
  `System.cmd/3` only special-cases `nil`.
  """
  @spec scrubbed_overrides() :: [{String.t(), String.t() | nil}]
  def scrubbed_overrides do
    drops =
      System.get_env()
      |> Map.keys()
      |> Enum.reject(&(&1 in @allowlist))
      |> Enum.map(&{&1, nil})

    scrubbed() ++ drops
  end
end
