defmodule Nous.Skills.PythonUv do
  @moduledoc "Built-in skill for Python's uv package manager and project tooling."
  use Nous.Skill, tags: [:python, :uv, :packaging, :dependencies], group: :coding

  @impl true
  def name, do: "python_uv"

  @impl true
  def description,
    do:
      "Python uv: fast package management, virtual environments, project scaffolding, and scripts"

  @impl true
  def instructions(_agent, _ctx) do
    """
    You are a Python uv specialist. uv is the modern, fast Python package and project manager (written in Rust). Follow these patterns:

    1. **Project initialization**:
       ```bash
       uv init my-project          # Create new project with pyproject.toml
       uv init --lib my-lib        # Create library project
       uv init --script script.py  # Create standalone script with inline deps
       ```

    2. **Dependency management** (replaces pip, pip-tools, poetry):
       ```bash
       uv add requests fastapi      # Add dependencies
       uv add --dev pytest ruff     # Add dev dependencies
       uv remove requests           # Remove dependency
       uv lock                      # Generate/update uv.lock
       uv sync                      # Install from lockfile
       ```

    3. **Running commands** (auto-creates venv, syncs deps):
       ```bash
       uv run python main.py       # Run with managed environment
       uv run pytest                # Run tests
       uv run ruff check .          # Run linter
       ```

    4. **Python version management** (replaces pyenv):
       ```bash
       uv python install 3.12       # Install Python version
       uv python pin 3.12           # Pin for project
       uv python list               # List available versions
       ```

    5. **Tool management** (replaces pipx):
       ```bash
       uv tool install ruff         # Install CLI tools globally
       uv tool run black .          # Run tool without install (uvx alias)
       uvx ruff check .             # Shorthand for uv tool run
       ```

    6. **Inline script dependencies** (PEP 723):
       ```python
       # /// script
       # requires-python = ">=3.12"
       # dependencies = ["requests", "rich"]
       # ///
       import requests, rich
       ```
       Run with: `uv run script.py`

    7. **pyproject.toml** is the single source of truth. Never use requirements.txt for new projects.

    8. **Always commit `uv.lock`** for applications (reproducible installs). Omit for libraries.

    9. **Workspaces** for monorepos: define `[tool.uv.workspace]` in root pyproject.toml.
    """
  end

  @impl true
  def match?(input) do
    input = String.downcase(input)

    String.contains?(input, [
      " uv ",
      "uv add",
      "uv run",
      "uv init",
      "uv sync",
      "uv pip",
      "uv tool",
      "uvx ",
      "pyproject.toml"
    ])
  end
end
