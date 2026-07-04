defmodule Nous.Tools.FileEdit do
  @moduledoc """
  String replacement editing tool.

  Edits files by finding and replacing exact string matches.
  By default requires `old_string` to be unique in the file
  to prevent unintended changes.
  """

  use Nous.Tool.Schema

  tool "file_edit",
    description:
      "Edit a file by replacing exact string matches. The old_string must be unique in the file unless replace_all is true.",
    category: :write,
    requires_approval: true do
    param(:file_path, :string, required: true, doc: "Path to the file to edit")
    param(:old_string, :string, required: true, doc: "The exact text to find and replace")
    param(:new_string, :string, required: true, doc: "The replacement text")

    param(:replace_all, :boolean,
      doc: "Replace all occurrences instead of requiring uniqueness. Defaults to false."
    )
  end

  @impl true
  def execute(
        ctx,
        %{"file_path" => file_path, "old_string" => old_string, "new_string" => new_string} =
          args
      ) do
    replace_all = Map.get(args, "replace_all", false)

    with {:ok, safe_path} <- Nous.Tools.PathGuard.validate(file_path, ctx),
         {:ok, content} <- File.read(safe_path) do
      occurrences = count_occurrences(content, old_string)

      cond do
        occurrences == 0 ->
          {:error, "old_string not found in #{safe_path}"}

        occurrences > 1 and not replace_all ->
          {:error,
           "old_string found #{occurrences} times in #{safe_path}. " <>
             "Use replace_all: true to replace all occurrences."}

        true ->
          new_content =
            if replace_all do
              String.replace(content, old_string, new_string)
            else
              replace_first(content, old_string, new_string)
            end

          case File.write(safe_path, new_content) do
            :ok ->
              replaced = if replace_all, do: occurrences, else: 1

              {:ok,
               "Edited #{safe_path} (#{replaced} replacement#{if replaced > 1, do: "s", else: ""})"}

            {:error, reason} ->
              {:error, "Failed to write #{safe_path}: #{inspect(reason)}"}
          end
      end
    else
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, "Failed to access #{file_path}: #{inspect(reason)}"}
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
