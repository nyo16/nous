defmodule Nous.Spill.Local do
  @moduledoc """
  Filesystem backend for `Nous.Spill`.

  ## Layout

      <root>/session-<sha256_hex(owner)>/<random>-<safe_name>

  `root` comes from `opts[:root]` and defaults to
  `Path.join(System.tmp_dir!(), "nous-spill")`.

  The owner is **hashed**, never used raw: a session id can contain a path
  separator, a `..`, or be derived from something a user controls, and any of
  those would let the owner steer the write out of `root`. A hex digest cannot.
  The `<random>` component means two saves with the same owner and name never
  collide, so a spilled result is never silently overwritten by a later one.

  ## Permissions

  Spilled content is whatever a tool just read or produced — file contents,
  command output, search hits. On a shared host that is nobody else's business,
  so the session directory is `0700` and each file is `0600`.

  Both need an explicit `File.chmod/2`. `File.mkdir_p/1` takes no mode
  argument, so a fresh directory is created at `0777 &&& ~umask`, which on a
  typical `022` umask leaves it group- and world-readable. `File.open/2` is the
  same story for the file. The file is chmodded *before* its bytes are written,
  so the content never exists on disk at the laxer inherited mode.

  ## Exclusive create

  Files are opened `[:write, :exclusive, :binary]`. Exclusive create is what
  stops a planted symlink from redirecting the write: `O_EXCL` fails outright if
  the path already exists — including as a symlink — instead of following it and
  truncating whatever it points at. A pre-created `<random>-<safe_name>` symlink
  is therefore an error, not an arbitrary-file overwrite.

  ## Retention

  Files persist until the operator deletes them. See the retention section of
  `Nous.Spill` for why there is deliberately no reaper here.
  """

  @behaviour Nous.Spill

  alias Nous.Spill.Locator

  @dirname "nous-spill"

  # 9 bytes -> 12 base64url characters, no padding. Ample against collision and
  # short enough to leave the readable part of the name visible.
  @random_bytes 9

  @max_name_bytes 64
  @fallback_name "result.txt"

  @dir_mode 0o700
  @file_mode 0o600

  @doc """
  Write `content` under `<root>/session-<sha256_hex(owner)>/<random>-<safe_name>`.

  `attrs` is the `t:Nous.Spill.attrs/0` map plus the `:opts` keyword list
  `Nous.Spill.save_text/2` injects from configuration. Only `opts[:root]` is
  read.

  Returns `{:error, term}` for every failure — a missing root, an unwritable
  directory, a full disk — and never leaves a partial file behind: if the write
  or the chmod fails after the file was created, the file is removed.
  """
  @impl true
  @spec save_text(Nous.Spill.attrs()) :: {:ok, Locator.t()} | {:error, term()}
  def save_text(%{owner: owner, content: content} = attrs)
      when is_binary(owner) and is_binary(content) do
    name = safe_name(Map.get(attrs, :suggested_name))

    with {:ok, root} <- root(Map.get(attrs, :opts, [])),
         dir = Path.join(root, "session-" <> hash(owner)),
         :ok <- ensure_dir(dir),
         {:ok, path} <- create(dir, name, content) do
      {:ok, %Locator{store: __MODULE__, id: path, bytes: byte_size(content), name: name}}
    end
  end

  @doc """
  Read a spilled file back, byte for byte.

  Returns `File.read/1`'s error tuples unchanged — `{:error, :enoent}` for a
  file the operator has since deleted, `{:error, :eacces}` for one it can no
  longer read.
  """
  @impl true
  @spec fetch(Locator.t()) :: {:ok, binary()} | {:error, term()}
  def fetch(%Locator{id: path}), do: File.read(path)

  @doc """
  Tell the model how to open this locator: the concrete path, and the tool.

  The hint names `file_read`, which is fenced to the workspace root by
  `Nous.Tools.PathGuard`. A spill `:root` outside that workspace therefore
  produces a path the model **cannot** read, and the hint does not pretend
  otherwise — it states where the content is and which tool opens it, and leaves
  reachability to the operator who chose the root. Keeping the spill root inside
  the workspace is what makes the hint actionable.
  """
  @impl true
  @spec retrieval_hint(Locator.t()) :: String.t()
  def retrieval_hint(%Locator{id: path}) do
    "Read the full result with the file_read tool at #{path}."
  end

  # ---------------------------------------------------------------------------

  defp root(opts) do
    case Keyword.get(opts, :root) do
      root when is_binary(root) -> {:ok, root}
      nil -> default_root()
      other -> {:error, {:invalid_root, other}}
    end
  end

  # System.tmp_dir/0, not tmp_dir!/0: save_text/1 promises an error tuple rather
  # than an exception, and a host with no usable temp directory is exactly the
  # kind of misconfiguration that must not take a tool call down with it. The
  # "nous-spill" subdirectory keeps session directories from scattering across
  # /tmp itself.
  defp default_root do
    case System.tmp_dir() do
      nil -> {:error, :no_tmp_dir}
      tmp -> {:ok, Path.join(tmp, @dirname)}
    end
  end

  defp hash(owner), do: :crypto.hash(:sha256, owner) |> Base.encode16(case: :lower)

  defp ensure_dir(dir) do
    with :ok <- File.mkdir_p(dir), do: File.chmod(dir, @dir_mode)
  end

  defp create(dir, name, content) do
    path = Path.join(dir, random() <> "-" <> name)

    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, io} -> write(path, io, content)
      {:error, reason} -> {:error, reason}
    end
  end

  defp write(path, io, content) do
    # chmod first: the exclusive create obeyed the umask, so tightening before
    # the bytes land means the content is never readable at the laxer mode.
    result = with :ok <- File.chmod(path, @file_mode), do: IO.binwrite(io, content)
    closed = File.close(io)

    case {result, closed} do
      {:ok, :ok} -> {:ok, path}
      {{:error, reason}, _closed} -> discard(path, reason)
      {:ok, {:error, reason}} -> discard(path, reason)
    end
  end

  # No half-written spill survives: a locator pointing at truncated content is
  # worse than no locator, because Nous.Spill's caller would have replaced the
  # real result with a preview of it.
  defp discard(path, reason) do
    _ = File.rm(path)
    {:error, reason}
  end

  defp random do
    @random_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  # The suggested name is advisory and comes from a tool result, so it is
  # untrusted input to a path. Everything outside [A-Za-z0-9._-] collapses to a
  # single "-", which is what kills separators; stripping leading dots and
  # dashes is what kills "..", "-flag", and dotfiles. Nothing that survives can
  # contain "/" or be a traversal component.
  defp safe_name(name) when is_binary(name) do
    name
    |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
    |> String.replace(~r/^[.\-]+/, "")
    |> truncate()
    |> case do
      "" -> @fallback_name
      safe -> safe
    end
  end

  defp safe_name(_other), do: @fallback_name

  # Post-sanitisation the name is pure ASCII, so a byte cut cannot split a
  # codepoint. Long names are pointless in a locator and some filesystems cap a
  # component at 255 bytes.
  defp truncate(name) when byte_size(name) <= @max_name_bytes, do: name
  defp truncate(name), do: binary_part(name, 0, @max_name_bytes)
end
