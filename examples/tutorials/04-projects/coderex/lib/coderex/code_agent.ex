defmodule Coderex.CodeAgent do
  @moduledoc """
  A code agent built on Nous that can read, write, and modify code files.

  ## Features

  - Read files and understand code structure
  - Write new files
  - Edit existing files using SEARCH/REPLACE blocks
  - Search for patterns across files
  - Execute shell commands
  - List directory contents

  ## Usage

      # Create an agent
      agent = Coderex.CodeAgent.new("anthropic:claude-haiku-4-5-20251001")

      # Run with a coding task
      {:ok, result} = Coderex.CodeAgent.run(agent, "Create a hello world function in lib/hello.ex")

      # Run with a specific working directory
      {:ok, result} = Coderex.CodeAgent.run(agent, "Fix the bug in main.ex",
        cwd: "/path/to/project"
      )
  """

  alias Coderex.Tools.FileTools
  alias Coderex.Tools.ShellTools

  @system_instructions """
  You are an expert software engineer and coding assistant. You help users with programming tasks by reading, writing, and modifying code files.

  ## Available Tools

  You have access to file and shell tools:

  - **read_file**: Read the contents of a file
  - **write_file**: Create a new file or overwrite an existing file completely
  - **edit_file**: Modify specific parts of a file using SEARCH/REPLACE blocks
  - **list_files**: List files in a directory with optional pattern matching
  - **search_files**: Search for text patterns across files
  - **file_info**: Get information about a file (exists, size, type)
  - **create_directory**: Create a new directory
  - **delete_file**: Delete a file
  - **execute_command**: Run a shell command

  ## Editing Files

  When editing files, use the `edit_file` tool with SEARCH/REPLACE blocks:

  ```
  ------- SEARCH
  [exact content to find - must match exactly including whitespace]
  =======
  [new content to replace with]
  +++++++ REPLACE
  ```

  Important rules for editing:
  1. The SEARCH content must match EXACTLY what's in the file (character-for-character)
  2. Include enough context (surrounding lines) to make the match unique
  3. You can have multiple SEARCH/REPLACE blocks in one edit
  4. To delete code, leave the REPLACE section empty
  5. ALWAYS read the file first before editing to ensure accurate matching

  ## Best Practices

  1. **Read before writing**: Always read a file before editing it
  2. **Small, focused changes**: Make targeted edits rather than rewriting entire files
  3. **Verify changes**: After editing, consider reading the file to verify the changes
  4. **Handle errors**: Check tool results for errors and handle them appropriately
  5. **Be precise**: Copy code exactly when creating SEARCH blocks

  ## Response Style

  - Be concise but thorough
  - Explain what you're doing and why
  - Show relevant code snippets when helpful
  - Report any errors encountered
  """

  @doc """
  Create a new code agent.

  ## Options

  - `:instructions` - Additional instructions to append to the system prompt
  - `:model_settings` - Model settings like temperature, max_tokens
  - `:tools` - Additional tools to include

  ## Example

      agent = Coderex.CodeAgent.new("anthropic:claude-haiku-4-5-20251001",
        instructions: "Focus on Elixir code",
        model_settings: %{temperature: 0.3}
      )
  """
  def new(model, opts \\ []) do
    extra_instructions = Keyword.get(opts, :instructions, "")
    model_settings = Keyword.get(opts, :model_settings, %{})
    extra_tools = Keyword.get(opts, :tools, [])

    instructions = if extra_instructions != "" do
      @system_instructions <> "\n\n## Additional Instructions\n\n" <> extra_instructions
    else
      @system_instructions
    end

    Nous.new(model,
      instructions: instructions,
      tools: core_tools() ++ extra_tools,
      model_settings: Map.merge(%{temperature: 0.2, max_tokens: 8192}, model_settings)
    )
  end

  @doc """
  Run the code agent with a task.

  ## Options

  - `:cwd` - Working directory for file operations (defaults to current directory)
  - `:message_history` - Previous conversation messages
  - `:max_iterations` - Maximum tool call iterations (default: 20)
  - `:deps` - Additional dependencies to pass to tools

  ## Example

      {:ok, result} = Coderex.CodeAgent.run(agent,
        "Add a new function called `greet` to lib/hello.ex",
        cwd: "/path/to/project"
      )

      # Continue conversation
      {:ok, result2} = Coderex.CodeAgent.run(agent,
        "Now add tests for the greet function",
        cwd: "/path/to/project",
        message_history: result.new_messages
      )
  """
  def run(agent, prompt, opts \\ []) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    message_history = Keyword.get(opts, :message_history, [])
    max_iterations = Keyword.get(opts, :max_iterations, 20)
    extra_deps = Keyword.get(opts, :deps, %{})

    deps = Map.merge(extra_deps, %{cwd: cwd})

    # Check for API key before running
    case check_api_key(agent.model) do
      :ok ->
        try do
          Nous.run(agent, prompt,
            deps: deps,
            message_history: message_history,
            max_iterations: max_iterations
          )
        rescue
          e in FunctionClauseError ->
            {:error, format_error(e)}
          e ->
            {:error, "Unexpected error: #{Exception.message(e)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Run the code agent with streaming output.

  Returns a stream that emits events like:
  - `{:text_delta, text}` - Partial text response
  - `{:tool_call, call}` - Tool being called
  - `{:tool_result, result}` - Tool result
  - `{:complete, result}` - Final result

  ## Example

      {:ok, stream} = Coderex.CodeAgent.run_stream(agent, "List all .ex files")

      stream
      |> Stream.each(fn
        {:text_delta, text} -> IO.write(text)
        {:tool_call, call} -> IO.puts("\\nCalling: \#{call.name}")
        {:complete, _} -> IO.puts("\\nDone!")
        _ -> :ok
      end)
      |> Stream.run()
  """
  def run_stream(agent, prompt, opts \\ []) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    message_history = Keyword.get(opts, :message_history, [])
    max_iterations = Keyword.get(opts, :max_iterations, 20)
    extra_deps = Keyword.get(opts, :deps, %{})

    deps = Map.merge(extra_deps, %{cwd: cwd})

    # Check for API key before running
    case check_api_key(agent.model) do
      :ok ->
        try do
          Nous.run_stream(agent, prompt,
            deps: deps,
            message_history: message_history,
            max_iterations: max_iterations
          )
        rescue
          e in FunctionClauseError ->
            {:error, format_error(e)}
          e ->
            {:error, "Unexpected error: #{Exception.message(e)}"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Check if the required API key is set for the provider
  defp check_api_key(%{provider: provider}) do
    check_provider_api_key(provider)
  end

  defp check_api_key(model) when is_binary(model) do
    cond do
      String.starts_with?(model, "anthropic:") -> check_provider_api_key(:anthropic)
      String.starts_with?(model, "openai:") -> check_provider_api_key(:openai)
      String.starts_with?(model, "google:") -> check_provider_api_key(:google)
      true -> :ok
    end
  end

  defp check_provider_api_key(:anthropic) do
    case System.get_env("ANTHROPIC_API_KEY") do
      nil -> {:error, "ANTHROPIC_API_KEY environment variable is not set. Please set it with: export ANTHROPIC_API_KEY=your_key"}
      "" -> {:error, "ANTHROPIC_API_KEY environment variable is empty. Please set a valid API key."}
      _ -> :ok
    end
  end

  defp check_provider_api_key(:openai) do
    case System.get_env("OPENAI_API_KEY") do
      nil -> {:error, "OPENAI_API_KEY environment variable is not set. Please set it with: export OPENAI_API_KEY=your_key"}
      "" -> {:error, "OPENAI_API_KEY environment variable is empty. Please set a valid API key."}
      _ -> :ok
    end
  end

  defp check_provider_api_key(:google) do
    case System.get_env("GOOGLE_API_KEY") do
      nil -> {:error, "GOOGLE_API_KEY environment variable is not set. Please set it with: export GOOGLE_API_KEY=your_key"}
      "" -> {:error, "GOOGLE_API_KEY environment variable is empty. Please set a valid API key."}
      _ -> :ok
    end
  end

  defp check_provider_api_key(_provider) do
    # Unknown provider, let it through and fail later if needed
    :ok
  end

  # Format error messages for common issues
  defp format_error(%FunctionClauseError{} = e) do
    cond do
      String.contains?(Exception.message(e), "Anthropix.init") ->
        "Anthropic API key is missing or invalid. Please set ANTHROPIC_API_KEY environment variable."

      String.contains?(Exception.message(e), "api_key") ->
        "API key is missing or invalid. Please check your environment variables."

      true ->
        "Configuration error: #{Exception.message(e)}"
    end
  end

  # Define core tools with proper schemas

  defp core_tools do
    [
      # File reading
      %Nous.Tool{
        name: "read_file",
        description: "Read the contents of a file. Returns the file content and line count.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "The file path to read (relative to working directory)"
            }
          },
          "required" => ["path"]
        },
        function: &FileTools.read_file/2,
        takes_ctx: true
      },

      # File writing
      %Nous.Tool{
        name: "write_file",
        description: "Write content to a file, creating it if it doesn't exist. Use this for creating new files or completely replacing file contents.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "The file path to write to"
            },
            "content" => %{
              "type" => "string",
              "description" => "The complete content to write to the file"
            }
          },
          "required" => ["path", "content"]
        },
        function: &FileTools.write_file/2,
        takes_ctx: true
      },

      # File editing with diff
      %Nous.Tool{
        name: "edit_file",
        description: """
        Modify specific parts of a file using SEARCH/REPLACE blocks.

        The diff format:
            ------- SEARCH
            [exact content to find - must match exactly]
            =======
            [new content to replace with]
            +++++++ REPLACE

        You can include multiple SEARCH/REPLACE blocks to make multiple changes.
        IMPORTANT: Always read the file first to ensure the SEARCH content matches exactly.
        """,
        parameters: %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "The file path to modify"
            },
            "diff" => %{
              "type" => "string",
              "description" => "The SEARCH/REPLACE block(s) to apply"
            }
          },
          "required" => ["path", "diff"]
        },
        function: &FileTools.edit_file/2,
        takes_ctx: true
      },

      # List files
      %Nous.Tool{
        name: "list_files",
        description: "List files in a directory with optional pattern matching.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "Directory path (defaults to working directory)"
            },
            "pattern" => %{
              "type" => "string",
              "description" => "Glob pattern to filter files (e.g., '*.ex', '*.js')"
            },
            "recursive" => %{
              "type" => "boolean",
              "description" => "Whether to list recursively (default: false)"
            }
          },
          "required" => []
        },
        function: &FileTools.list_files/2,
        takes_ctx: true
      },

      # Search files
      %Nous.Tool{
        name: "search_files",
        description: "Search for a text pattern across files. Returns matching lines with file paths and line numbers.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "pattern" => %{
              "type" => "string",
              "description" => "The regex pattern to search for"
            },
            "path" => %{
              "type" => "string",
              "description" => "Directory to search in (defaults to working directory)"
            },
            "glob" => %{
              "type" => "string",
              "description" => "File pattern to search (e.g., '*.ex')"
            },
            "max_results" => %{
              "type" => "integer",
              "description" => "Maximum number of results (default: 50)"
            }
          },
          "required" => ["pattern"]
        },
        function: &FileTools.search_files/2,
        takes_ctx: true
      },

      # File info
      %Nous.Tool{
        name: "file_info",
        description: "Get information about a file (exists, size, type, modification time).",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "The file path to check"
            }
          },
          "required" => ["path"]
        },
        function: &FileTools.file_info/2,
        takes_ctx: true
      },

      # Create directory
      %Nous.Tool{
        name: "create_directory",
        description: "Create a new directory (including parent directories if needed).",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "The directory path to create"
            }
          },
          "required" => ["path"]
        },
        function: &FileTools.create_directory/2,
        takes_ctx: true
      },

      # Delete file
      %Nous.Tool{
        name: "delete_file",
        description: "Delete a file.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" => "The file path to delete"
            }
          },
          "required" => ["path"]
        },
        function: &FileTools.delete_file/2,
        takes_ctx: true
      },

      # Execute command
      %Nous.Tool{
        name: "execute_command",
        description: "Execute a shell command. Use for running builds, tests, installations, etc.",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "command" => %{
              "type" => "string",
              "description" => "The shell command to execute"
            },
            "timeout" => %{
              "type" => "integer",
              "description" => "Timeout in milliseconds (default: 60000)"
            }
          },
          "required" => ["command"]
        },
        function: &ShellTools.execute_command/2,
        takes_ctx: true
      }
    ]
  end
end
