defmodule Nous.OutputSchema.UseMacro do
  @moduledoc false
  # Provides the `use Nous.OutputSchema` macro implementation.

  defmacro __using__(_opts) do
    quote do
      @behaviour Nous.OutputSchema.Validator

      Module.register_attribute(__MODULE__, :llm_doc, persist: true)
      @llm_doc nil

      @before_compile Nous.OutputSchema.UseMacro
    end
  end

  defmacro __before_compile__(env) do
    llm_doc =
      case Module.get_attribute(env.module, :llm_doc) do
        nil -> nil
        doc -> doc
      end

    quote do
      @doc false
      def __llm_doc__, do: unquote(llm_doc)
    end
  end
end
