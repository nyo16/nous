defmodule Nous.Sandbox.Policy do
  @moduledoc """
  What a confined subprocess is allowed to do.

  A policy is plain data: a mode, the workspace root the mode is relative to,
  and an optional session id for logging/telemetry. It is resolved per call
  (see `resolve/2`) and handed to `Nous.Sandbox.confine/2`, which turns it into
  argv. Nothing here spawns.

  ## Modes

    * `:read_only` — the process may read, but every write is denied. No
      writable roots at all (`Nous.Sandbox.writable_roots/1` returns `[]`).
    * `:workspace_write` — writes are allowed under the workspace root and the
      temp directories, denied everywhere else.
    * `:danger_full_access` — no confinement. `Nous.Sandbox.confine/2` does not
      call a provider at all and the argv is passed through untouched.

  Note what *no* mode does: neither in-tree provider restricts **reads**.
  Seatbelt's profile is `(allow default) (deny file-write*)` and bwrap binds
  `/` read-only, so both are write fences. Read confinement remains
  `Nous.Tools.PathGuard`'s job.

  ## Where the mode comes from

  Precedence, highest first (`resolve/2`):

    1. an explicit `:mode` passed to `resolve/2`
    2. the session policy carried on the context (`ctx.sandbox`), which is
       `Nous.Agent`'s `:sandbox` option, overridable per run
    3. the application default (`config :nous, :sandbox_mode, ...`)

  ## The default is permissive, on purpose, for now

  With no configuration the default is `:danger_full_access` and a one-time
  warning is logged. Fail-closed confinement is a *behaviour* change even
  though it is not an API change: `Nous.Tools.Bash` would stop working on any
  host without `bwrap` installed. Opting in is one line:

      config :nous, :sandbox_mode, :workspace_write

  The default will flip in a later release.

  ## What breaks when you turn it on

  Measured, so you meet it here rather than in production. A fence people switch
  off is worse than a fence with a named exception.

  Under `:read_only` there are **no** writable roots — not even the temp dir — so
  the shell cannot create the temp file a **heredoc** needs (`cannot create temp
  file for here document`), and `mktemp` fails. Heredocs are how a model writes
  multi-line content in shell, so `:read_only` is for genuinely read-only work
  (inspection, search, `git log`), not for "mostly reading".

  Under `:workspace_write`, `$HOME` is read-only, which breaks any tool that
  writes a cache there: `npm` (`EPERM ... ~/.npm/_cacache`), `pip`'s wheel cache,
  `cargo`'s `~/.cargo`, `go build`'s cache, `gh`, `docker`'s `~/.docker`. `git`
  is fine — its writes live in the repo.

  When that bites, widen deliberately rather than reaching for
  `:danger_full_access`: give the agent its own `workspace_root` and point the
  tool's cache into it (`HOME=<root> npm ci`, `CARGO_HOME=<root>/.cargo`), or drop
  to `:read_only`/`:workspace_write` per run with the `:sandbox` option instead of
  globally.
  """

  alias __MODULE__
  alias Nous.Tools.PathGuard

  require Logger

  @type mode :: :read_only | :workspace_write | :danger_full_access

  @type t :: %Policy{
          mode: mode(),
          workspace_root: Path.t(),
          session_id: String.t() | nil
        }

  @enforce_keys [:mode, :workspace_root]
  defstruct [:mode, :workspace_root, session_id: nil]

  @modes [:read_only, :workspace_write, :danger_full_access]

  @default_mode :danger_full_access

  @doc """
  The three valid modes, widest confinement first.
  """
  @spec modes() :: [mode()]
  def modes, do: @modes

  @doc """
  Build a policy from a mode, a keyword list, a map, or another policy.

  `:workspace_root` defaults to the current working directory, matching
  `Nous.Tools.PathGuard`.

  ## Examples

      iex> Nous.Sandbox.Policy.new(:read_only).mode
      :read_only

      iex> policy = Nous.Sandbox.Policy.new(mode: :workspace_write, workspace_root: "/srv/ws")
      iex> {policy.mode, policy.workspace_root}
      {:workspace_write, "/srv/ws"}

  """
  @spec new(t() | mode() | String.t() | keyword() | map()) :: t()
  def new(%Policy{} = policy), do: policy

  def new(mode) when is_atom(mode) or is_binary(mode) do
    new(mode: mode)
  end

  def new(opts) when is_list(opts), do: new(Map.new(opts))

  def new(%{} = opts) do
    %Policy{
      # get_lazy, not get/3: `default_mode/0` warns when nothing is configured,
      # and evaluating it eagerly would claim "subprocesses run unconfined" at
      # the exact moment a caller asked for :read_only — then stay silent for
      # the real unconfined case, since the warning fires once per VM. It would
      # also raise on unrelated bad global config an explicit policy never uses.
      mode: coerce_mode!(Map.get_lazy(opts, :mode, &default_mode/0)),
      workspace_root: expand_root(Map.get(opts, :workspace_root)),
      session_id: Map.get(opts, :session_id)
    }
  end

  @doc """
  Resolve the effective policy for a tool call.

  `ctx` is a `Nous.RunContext` (or any map with `:sandbox`/`:deps` keys, or
  `nil`). `opts` may override `:mode`, `:workspace_root` and `:session_id`.

  The workspace root falls back to `ctx.deps[:workspace_root]` — the same place
  `Nous.Tools.PathGuard` reads it from — and then to the current directory.
  """
  @spec resolve(Nous.RunContext.t() | map() | nil, keyword()) :: t()
  def resolve(ctx, opts \\ []) do
    session = session_policy(ctx)
    deps = deps_of(ctx)

    new(
      mode:
        Keyword.get(opts, :mode) || (session && session.mode) ||
          default_mode(),
      workspace_root:
        Keyword.get(opts, :workspace_root) || (session && session.workspace_root) ||
          Map.get(deps, :workspace_root),
      session_id:
        Keyword.get(opts, :session_id) || (session && session.session_id) ||
          Map.get(deps, :session_id)
    )
  end

  @doc """
  The configured application-wide default mode.

  Warns once per VM when nothing is configured, because the built-in default
  runs subprocesses unconfined (see the moduledoc).
  """
  @spec default_mode() :: mode()
  def default_mode do
    case Application.get_env(:nous, :sandbox_mode) do
      nil ->
        warn_permissive_default_once()
        @default_mode

      configured ->
        coerce_mode!(configured)
    end
  end

  @doc """
  Canonicalise a path: absolute, with every existing symlink component
  dereferenced, via `Nous.Tools.PathGuard.resolve_real/1`.

  This is why policy construction, not `Nous.Sandbox.confine/2`, is where the
  filesystem is touched. It matters for enforcement, not tidiness: on macOS
  `/tmp` is a symlink to `/private/tmp`, and an SBPL `(subpath "/tmp")` clause
  would never match a write the kernel sees as `/private/tmp/...`.

  Falls back to `Path.expand/1` on a symlink loop.
  """
  @spec canonical(Path.t()) :: Path.t()
  def canonical(path) when is_binary(path) do
    case PathGuard.resolve_real(path) do
      {:ok, real} -> real
      {:error, _symlink_loop} -> Path.expand(path)
    end
  end

  # ---------------------------------------------------------------------------

  # Never String.to_atom/1 on configuration that may come from an env var:
  # match a literal whitelist instead.
  defp coerce_mode!(mode) when mode in @modes, do: mode
  defp coerce_mode!("read_only"), do: :read_only
  defp coerce_mode!("workspace_write"), do: :workspace_write
  defp coerce_mode!("danger_full_access"), do: :danger_full_access

  defp coerce_mode!(other) do
    raise ArgumentError,
          "invalid sandbox mode #{inspect(other)}; expected one of #{inspect(@modes)}"
  end

  defp expand_root(nil), do: expand_root(File.cwd!())

  defp expand_root(root) when is_binary(root) do
    # A NUL truncates the SBPL profile mid-string, which happens to fail closed
    # (`sandbox-exec` exits 65 on the unterminated string) — by luck, not design.
    # Reject it explicitly, the way PathGuard does for paths.
    if String.contains?(root, <<0>>) do
      raise ArgumentError, "sandbox workspace_root contains a NUL byte"
    end

    case canonical(root) do
      "/" ->
        # `(subpath "/")` re-allows the entire filesystem, and `--bind / /` after
        # `--ro-bind / /` restores read-write on the whole tree — while the
        # %Confined{} still advertises `enforcement: :sandbox_exec` and every log
        # line still says "confined". A fence that silently fences nothing is
        # worse than no fence, and this is reachable by ACCIDENT, not only by
        # misconfiguration: the root defaults to `File.cwd!/0`.
        raise ArgumentError,
              "sandbox workspace_root cannot be \"/\": under :workspace_write that " <>
                "re-allows writes to the entire filesystem while still reporting " <>
                "confinement. Point it at the directory the agent owns."

      canonical ->
        canonical
    end
  end

  defp session_policy(%{sandbox: %Policy{} = policy}), do: policy
  defp session_policy(_ctx), do: nil

  defp deps_of(%{deps: deps}) when is_map(deps), do: deps
  defp deps_of(_ctx), do: %{}

  @warned_key {__MODULE__, :permissive_default_warned}

  defp warn_permissive_default_once do
    if :persistent_term.get(@warned_key, nil) do
      :ok
    else
      :persistent_term.put(@warned_key, true)

      Logger.warning(
        "Nous sandbox mode is unset, defaulting to :danger_full_access — subprocesses " <>
          "(Nous.Tools.Bash) run unconfined. Set `config :nous, :sandbox_mode, " <>
          ":workspace_write` to confine them. This default will flip in a later release."
      )
    end
  end
end
