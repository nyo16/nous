defmodule Coderex.Tools.ShellTools do
  @moduledoc """
  Shell command execution tools for the code agent.

  Provides safe command execution with timeout and output capture.
  """

  @default_timeout 60_000  # 60 seconds

  @doc """
  Execute a shell command.

  Parameters:
    - command: The command to execute
    - timeout: Timeout in milliseconds (default: 60000)

  Returns stdout, stderr, and exit code.
  """
  def execute_command(ctx, args) do
    command = Map.fetch!(args, "command")
    timeout = Map.get(args, "timeout", @default_timeout)
    cwd = ctx.deps[:cwd] || File.cwd!()

    # Basic safety check - don't allow obviously dangerous commands
    if dangerous_command?(command) do
      %{
        error: "Command rejected for safety reasons",
        command: command
      }
    else
      execute_with_timeout(command, cwd, timeout)
    end
  end

  defp execute_with_timeout(command, cwd, timeout) do
    task = Task.async(fn ->
      # Use System.cmd with shell for proper command parsing
      try do
        {output, exit_code} = System.shell(command, cd: cwd, stderr_to_stdout: true)
        %{
          command: command,
          output: truncate_output(output),
          exit_code: exit_code,
          success: exit_code == 0
        }
      rescue
        e ->
          %{
            command: command,
            error: Exception.message(e),
            success: false
          }
      end
    end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        %{
          command: command,
          error: "Command timed out after #{timeout}ms",
          success: false
        }
    end
  end

  defp truncate_output(output, max_length \\ 30_000) do
    if byte_size(output) > max_length do
      String.slice(output, 0, max_length) <> "\n... [output truncated]"
    else
      output
    end
  end

  # Basic safety checks - extend as needed
  defp dangerous_command?(command) do
    dangerous_patterns = [
      ~r/rm\s+-rf\s+[\/~]/,        # rm -rf / or ~
      ~r/:\(\)\s*\{\s*:\|:&\s*\}/, # Fork bomb
      ~r/mkfs\./,                   # Format disk
      ~r/dd\s+if=.*of=\/dev/,      # Overwrite device
      ~r/>\s*\/dev\/sd/,           # Write to disk device
      ~r/curl.*\|\s*(ba)?sh/,      # Pipe curl to shell
      ~r/wget.*\|\s*(ba)?sh/,      # Pipe wget to shell
    ]

    Enum.any?(dangerous_patterns, &Regex.match?(&1, command))
  end
end
