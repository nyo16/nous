defmodule Nous.Tools.Bash do
  @moduledoc """
  Shell command execution tool.

  Uses `NetRunner` for safe process execution with automatic timeout
  handling and output size limits. Zero zombie processes guaranteed.

  ## Security

  Commands run as the current OS user. Use `Nous.Permissions` to gate
  access to this tool in production.
  """

  @behaviour Nous.Tool.Behaviour

  @default_timeout 120_000
  @max_output_size 1_000_000

  @impl true
  def metadata do
    %{
      name: "bash",
      description: "Execute a shell command and return its output.",
      category: :execute,
      requires_approval: true,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "command" => %{
            "type" => "string",
            "description" => "The shell command to execute"
          },
          "timeout" => %{
            "type" => "integer",
            "description" => "Timeout in milliseconds. Defaults to 120000 (2 minutes)."
          }
        },
        "required" => ["command"]
      }
    }
  end

  @impl true
  def execute(_ctx, %{"command" => command} = args) do
    timeout = Map.get(args, "timeout", @default_timeout)

    result =
      NetRunner.run(["sh", "-c", command],
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
end
