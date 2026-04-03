defmodule Nous.Tools.FileEdit do
  @moduledoc """
  String replacement editing tool.

  Edits files by finding and replacing exact string matches.
  By default requires `old_string` to be unique in the file
  to prevent unintended changes.
  """

  @behaviour Nous.Tool.Behaviour

  @impl true
  def metadata do
    %{
      name: "file_edit",
      description:
        "Edit a file by replacing exact string matches. The old_string must be unique in the file unless replace_all is true.",
      category: :write,
      requires_approval: true,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{
            "type" => "string",
            "description" => "Path to the file to edit"
          },
          "old_string" => %{
            "type" => "string",
            "description" => "The exact text to find and replace"
          },
          "new_string" => %{
            "type" => "string",
            "description" => "The replacement text"
          },
          "replace_all" => %{
            "type" => "boolean",
            "description" =>
              "Replace all occurrences instead of requiring uniqueness. Defaults to false."
          }
        },
        "required" => ["file_path", "old_string", "new_string"]
      }
    }
  end

  @impl true
  def execute(
        _ctx,
        %{"file_path" => file_path, "old_string" => old_string, "new_string" => new_string} =
          args
      ) do
    replace_all = Map.get(args, "replace_all", false)

    case File.read(file_path) do
      {:ok, content} ->
        occurrences = count_occurrences(content, old_string)

        cond do
          occurrences == 0 ->
            {:error, "old_string not found in #{file_path}"}

          occurrences > 1 and not replace_all ->
            {:error,
             "old_string found #{occurrences} times in #{file_path}. " <>
               "Use replace_all: true to replace all occurrences."}

          true ->
            new_content =
              if replace_all do
                String.replace(content, old_string, new_string)
              else
                replace_first(content, old_string, new_string)
              end

            case File.write(file_path, new_content) do
              :ok ->
                replaced = if replace_all, do: occurrences, else: 1

                {:ok,
                 "Edited #{file_path} (#{replaced} replacement#{if replaced > 1, do: "s", else: ""})"}

              {:error, reason} ->
                {:error, "Failed to write #{file_path}: #{inspect(reason)}"}
            end
        end

      {:error, reason} ->
        {:error, "Failed to read #{file_path}: #{inspect(reason)}"}
    end
  end

  defp count_occurrences(string, substring) do
    parts = String.split(string, substring)
    length(parts) - 1
  end

  defp replace_first(string, old, new) do
    case String.split(string, old, parts: 2) do
      [before, rest] -> before <> new <> rest
      [_no_match] -> string
    end
  end
end
