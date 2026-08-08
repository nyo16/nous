defmodule Nous.Tools.Bash do
  @moduledoc """
  Shell command execution tool.

  Uses `NetRunner` for safe process execution with automatic timeout
  handling and output size limits. Zero zombie processes guaranteed.

  ## Security

  Commands run as the current OS user. Use `Nous.Permissions` to gate
  access to this tool in production.
  """

  use Nous.Tool.Schema

  @default_timeout 120_000
  # SECURITY: `timeout` is model-controlled, so `@default_timeout` bounds
  # nothing on its own. This is the hard ceiling; override with
  # `config :nous, :bash_max_timeout, ms`.
  @max_timeout 600_000
  @max_output_size 1_000_000

  tool "bash",
    description: "Execute a shell command and return its output.",
    category: :execute,
    requires_approval: true do
    param(:command, :string, required: true, doc: "The shell command to execute")

    param(:timeout, :integer,
      doc:
        "Timeout in milliseconds. Defaults to 120000 (2 minutes), clamped to the host's ceiling."
    )
  end

  @impl true
  def execute(_ctx, %{"command" => command} = args) do
    timeout = resolve_timeout(args)

    # Absolute path to /bin/sh, and `Env.scrub_argv/1` re-execs through
    # `env -i` so the shell doesn't inherit OPENAI_API_KEY / BRAVE_API_KEY /
    # TAVILY_API_KEY etc. A bare `env:` option cannot do this: NetRunner has
    # no such option and drops it silently. See `Nous.Tools.Env`.
    result =
      NetRunner.run(Nous.Tools.Env.scrub_argv(["/bin/sh", "-c", command]),
        timeout: timeout,
        max_output_size: @max_output_size
      )

    case result do
      {:error, :timeout} ->
        {:error, "Command timed out after #{timeout}ms"}

      {:error, {:max_output_exceeded, partial}} ->
        {:ok, "#{partial}\n\n[Output truncated at #{@max_output_size} bytes]"}

      {:error, reason} ->
        {:error, "Command failed: #{inspect(reason)}"}

      {output, 0} ->
        {:ok, output}

      {output, exit_code} ->
        {:ok, "Exit code: #{exit_code}\n#{output}"}
    end
  end

  defp resolve_timeout(args) do
    ceiling = Application.get_env(:nous, :bash_max_timeout, @max_timeout)

    case Map.get(args, "timeout", @default_timeout) do
      timeout when is_integer(timeout) and timeout > 0 -> min(timeout, ceiling)
      _ -> min(@default_timeout, ceiling)
    end
  end
end
