defmodule Coderex do
  @moduledoc """
  Coderex - A code agent built on Yggdrasil.

  Coderex is an AI-powered coding assistant that can read, write, and modify
  code files using natural language instructions.

  ## Quick Start

      # Create an agent
      agent = Coderex.new("anthropic:claude-sonnet-4-20250514")

      # Run a coding task
      {:ok, result} = Coderex.run(agent, "Create a hello world module")

  ## Features

  - Read and understand code files
  - Write new files
  - Edit existing files using precise SEARCH/REPLACE blocks
  - Search for patterns across codebases
  - Execute shell commands
  - List and navigate directories

  See `Coderex.CodeAgent` for detailed documentation.
  """

  defdelegate new(model, opts \\ []), to: Coderex.CodeAgent
  defdelegate run(agent, prompt, opts \\ []), to: Coderex.CodeAgent
  defdelegate run_stream(agent, prompt, opts \\ []), to: Coderex.CodeAgent
end
