defmodule Nous.Skill.Loader do
  @moduledoc """
  Loads skills from markdown files with YAML frontmatter.

  Supports progressive disclosure: only frontmatter is parsed initially,
  the full markdown body is loaded on first activation.

  ## File Format

      ---
      name: code_review
      description: Reviews code for quality and bugs
      tags: [code, review]
      group: review
      activation: auto
      allowed_tools: [read_file, grep]
      priority: 100
      ---

      You are a code review specialist...
  """

  alias Nous.Skill

  require Logger

  @doc """
  Load all `.md` skill files from a directory (recursively).

  Returns skills with only frontmatter parsed (status: :discovered).
  """
  @spec load_directory(String.t()) :: [Skill.t()]
  def load_directory(path) do
    path = Path.expand(path)

    if File.dir?(path) do
      Path.wildcard(Path.join(path, "**/*.md"))
      |> Enum.map(&load_file/1)
      |> Enum.filter(fn
        {:ok, _} ->
          true

        {:error, reason} ->
          Logger.warning("Failed to load skill file: #{inspect(reason)}")
          false
      end)
      |> Enum.map(fn {:ok, skill} -> skill end)
    else
      Logger.warning("Skills directory not found: #{path}")
      []
    end
  end

  @doc """
  Load a single skill from a markdown file.

  Parses YAML frontmatter for metadata. The markdown body is stored
  but marked as `status: :discovered` for lazy loading.
  """
  @spec load_file(String.t()) :: {:ok, Skill.t()} | {:error, term()}
  def load_file(path) do
    path = Path.expand(path)

    case File.read(path) do
      {:ok, content} ->
        parse_skill(content, path)

      {:error, reason} ->
        {:error, {:read_failed, path, reason}}
    end
  end

  @doc """
  Parse a skill from raw markdown content with YAML frontmatter.
  """
  @spec parse_skill(String.t(), String.t() | nil) :: {:ok, Skill.t()} | {:error, term()}
  def parse_skill(content, source_path \\ nil) do
    case parse_frontmatter(content) do
      {:ok, metadata, body} ->
        skill = %Skill{
          name: Map.get(metadata, "name", path_to_name(source_path)),
          description: Map.get(metadata, "description", ""),
          tags: parse_tags(Map.get(metadata, "tags", [])),
          group: parse_atom(Map.get(metadata, "group")),
          instructions: String.trim(body),
          activation: parse_activation(Map.get(metadata, "activation", "manual")),
          scope: :project,
          source: :file,
          source_ref: source_path,
          model_override: Map.get(metadata, "model_override"),
          allowed_tools: parse_string_list(Map.get(metadata, "allowed_tools")),
          priority: Map.get(metadata, "priority", 100),
          status: :loaded
        }

        {:ok, skill}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Parse YAML frontmatter from markdown content.

  Returns `{:ok, metadata_map, body}` or `{:error, reason}`.
  """
  @spec parse_frontmatter(String.t()) :: {:ok, map(), String.t()} | {:error, term()}
  def parse_frontmatter(content) do
    case String.split(content, ~r/^---\s*$/m, parts: 3) do
      [_, yaml, body] ->
        case YamlElixir.read_from_string(yaml) do
          {:ok, metadata} when is_map(metadata) ->
            {:ok, metadata, body}

          {:ok, _} ->
            {:error, :invalid_frontmatter}

          {:error, reason} ->
            {:error, {:yaml_parse_error, reason}}
        end

      _ ->
        # No frontmatter — treat entire content as instructions
        {:ok, %{}, content}
    end
  end

  # Convert file path to skill name (e.g., "priv/skills/code_review.md" -> "code_review")
  defp path_to_name(nil), do: "unnamed"

  defp path_to_name(path) do
    path
    |> Path.basename()
    |> Path.rootname()
  end

  defp parse_tags(tags) when is_list(tags), do: Enum.map(tags, &parse_atom/1)
  defp parse_tags(_), do: []

  # Common tag atoms (auto, manual, elixir, python, etc.) are already known;
  # String.to_existing_atom/1 will resolve them without creating new atoms.
  # Unknown tags fall through to String.to_atom/1 with a debug log.

  defp parse_atom(nil), do: nil
  defp parse_atom(val) when is_atom(val), do: val

  defp parse_atom(val) when is_binary(val) do
    String.to_existing_atom(val)
  rescue
    ArgumentError ->
      Logger.debug("Creating new atom for skill tag: #{val}")
      String.to_atom(val)
  end

  defp parse_atom(_), do: nil

  defp parse_activation("auto"), do: :auto
  defp parse_activation("manual"), do: :manual
  defp parse_activation(:auto), do: :auto
  defp parse_activation(:manual), do: :manual
  defp parse_activation(_), do: :manual

  defp parse_string_list(nil), do: nil
  defp parse_string_list(list) when is_list(list), do: Enum.map(list, &to_string/1)
  defp parse_string_list(_), do: nil
end
