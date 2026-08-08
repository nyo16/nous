defmodule Nous.Errors.Base do
  @moduledoc false

  # Shared construction for Nous exception modules.
  #
  # `use Nous.Errors.Base, fields: [...]` generates the `defexception` and the
  # two `exception/1` clauses every Nous error shares: a keyword form taking
  # the declared fields plus an optional `:message` override, and a bare-binary
  # message form. The using module supplies a private `default_message/1`,
  # which receives the map of declared fields and returns the message used
  # when `:message` is not given.
  #
  #     defmodule MyError do
  #       use Nous.Errors.Base, fields: [:reason]
  #
  #       defp default_message(%{reason: reason}) do
  #         "It broke" <> if(reason, do: ": #{reason}", else: "")
  #       end
  #     end
  #
  # Private on purpose: it is scaffolding for the exceptions Nous itself
  # defines in `Nous.Errors`, not a macro downstreams are meant to `use`.
  # The exceptions it generates are the published surface.

  defmacro __using__(opts) do
    fields = Keyword.fetch!(opts, :fields)

    quote do
      defexception [:message | unquote(fields)]

      @impl Exception
      def exception(opts) when is_list(opts) do
        fields = Map.new(unquote(fields), fn field -> {field, Keyword.get(opts, field)} end)
        message = Keyword.get(opts, :message) || default_message(fields)
        struct!(__MODULE__, Map.put(fields, :message, message))
      end

      def exception(message) when is_binary(message) do
        %__MODULE__{message: message}
      end
    end
  end
end
