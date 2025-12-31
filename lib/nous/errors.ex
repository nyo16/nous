defmodule Nous.Errors do
  @moduledoc """
  Custom error types for Nous AI.

  These exceptions provide structured error information for different
  failure scenarios in agent execution.
  """

  defmodule ConfigurationError do
    @moduledoc """
    Error in configuration or missing dependencies.

    Raised when required configuration is missing or a required
    optional dependency is not available.
    """

    defexception [:message, :details]

    @type t :: %__MODULE__{
            message: String.t(),
            details: any()
          }

    @impl true
    def exception(opts) when is_list(opts) do
      message = Keyword.get(opts, :message, "Configuration error")
      details = Keyword.get(opts, :details)

      %__MODULE__{
        message: message,
        details: details
      }
    end

    def exception(message) when is_binary(message) do
      %__MODULE__{message: message}
    end
  end

  defmodule ModelError do
    @moduledoc """
    Error from the model provider API.

    Raised when the underlying model API returns an error.

    Note: Consider using `ProviderError` for new code.
    """

    defexception [:message, :provider, :status_code, :details]

    @type t :: %__MODULE__{
            message: String.t(),
            provider: atom() | nil,
            status_code: integer() | nil,
            details: any()
          }

    @impl true
    def exception(opts) when is_list(opts) do
      provider = Keyword.get(opts, :provider)
      status_code = Keyword.get(opts, :status_code)
      details = Keyword.get(opts, :details)

      message =
        opts[:message] ||
          "Model request failed" <>
            if(provider, do: " (#{provider})", else: "") <>
            if(status_code, do: " [#{status_code}]", else: "")

      %__MODULE__{
        message: message,
        provider: provider,
        status_code: status_code,
        details: details
      }
    end

    def exception(message) when is_binary(message) do
      %__MODULE__{message: message}
    end
  end

  defmodule ProviderError do
    @moduledoc """
    Error from an LLM provider.

    Raised when a provider API call fails.
    """

    defexception [:message, :provider, :status_code, :details]

    @type t :: %__MODULE__{
            message: String.t(),
            provider: atom() | nil,
            status_code: integer() | nil,
            details: any()
          }

    @impl true
    def exception(opts) when is_list(opts) do
      provider = Keyword.get(opts, :provider)
      status_code = Keyword.get(opts, :status_code)
      details = Keyword.get(opts, :details)

      message =
        opts[:message] ||
          "Provider request failed" <>
            if(provider, do: " (#{provider})", else: "") <>
            if(status_code, do: " [#{status_code}]", else: "")

      %__MODULE__{
        message: message,
        provider: provider,
        status_code: status_code,
        details: details
      }
    end

    def exception(message) when is_binary(message) do
      %__MODULE__{message: message}
    end
  end

  defmodule ToolError do
    @moduledoc """
    Error during tool execution.

    Raised when a tool function fails during execution.
    """

    defexception [:message, :tool_name, :attempt, :original_error]

    @type t :: %__MODULE__{
            message: String.t(),
            tool_name: String.t() | nil,
            attempt: non_neg_integer() | nil,
            original_error: any()
          }

    @impl true
    def exception(opts) when is_list(opts) do
      tool_name = Keyword.get(opts, :tool_name)
      attempt = Keyword.get(opts, :attempt)
      original_error = Keyword.get(opts, :original_error)

      message =
        opts[:message] ||
          "Tool execution failed" <>
            if(tool_name, do: " (#{tool_name})", else: "") <>
            if(attempt, do: " after #{attempt} attempt(s)", else: "")

      %__MODULE__{
        message: message,
        tool_name: tool_name,
        attempt: attempt,
        original_error: original_error
      }
    end

    def exception(message) when is_binary(message) do
      %__MODULE__{message: message}
    end
  end

  defmodule ValidationError do
    @moduledoc """
    Error during output validation.

    Raised when structured output fails Ecto validation.
    """

    defexception [:message, :errors, :output_type]

    @type t :: %__MODULE__{
            message: String.t(),
            errors: keyword() | nil,
            output_type: module() | nil
          }

    @impl true
    def exception(opts) when is_list(opts) do
      errors = Keyword.get(opts, :errors)
      output_type = Keyword.get(opts, :output_type)

      message =
        opts[:message] ||
          "Output validation failed" <>
            if(output_type, do: " for #{inspect(output_type)}", else: "")

      %__MODULE__{
        message: message,
        errors: errors,
        output_type: output_type
      }
    end

    def exception(message) when is_binary(message) do
      %__MODULE__{message: message}
    end
  end

  defmodule UsageLimitExceeded do
    @moduledoc """
    Error when usage limits are exceeded.

    Raised when an agent run exceeds configured limits for
    requests, tokens, or tool calls.
    """

    defexception [:message, :limit_type, :limit_value, :actual_value]

    @type t :: %__MODULE__{
            message: String.t(),
            limit_type: atom() | nil,
            limit_value: integer() | nil,
            actual_value: integer() | nil
          }

    @impl true
    def exception(opts) when is_list(opts) do
      limit_type = Keyword.get(opts, :limit_type)
      limit_value = Keyword.get(opts, :limit_value)
      actual_value = Keyword.get(opts, :actual_value)

      message =
        opts[:message] ||
          "Usage limit exceeded" <>
            if(limit_type, do: " (#{limit_type})", else: "") <>
            if(limit_value && actual_value,
              do: ": #{actual_value} > #{limit_value}",
              else: ""
            )

      %__MODULE__{
        message: message,
        limit_type: limit_type,
        limit_value: limit_value,
        actual_value: actual_value
      }
    end

    def exception(message) when is_binary(message) do
      %__MODULE__{message: message}
    end
  end

  defmodule MaxIterationsExceeded do
    @moduledoc """
    Error when agent loop exceeds maximum iterations.

    Raised when an agent makes too many back-and-forth calls
    with the model, possibly indicating an infinite loop.
    """

    defexception [:message, :max_iterations]

    @type t :: %__MODULE__{
            message: String.t(),
            max_iterations: pos_integer() | nil
          }

    @impl true
    def exception(opts) when is_list(opts) do
      max_iterations = Keyword.get(opts, :max_iterations)

      message =
        opts[:message] ||
          "Maximum iterations exceeded" <>
            if(max_iterations, do: " (#{max_iterations})", else: "")

      %__MODULE__{
        message: message,
        max_iterations: max_iterations
      }
    end

    def exception(message) when is_binary(message) do
      %__MODULE__{message: message}
    end
  end

  defmodule ExecutionCancelled do
    @moduledoc """
    Error when agent execution is cancelled.

    Raised when an agent execution is explicitly cancelled
    by the user or system.
    """

    defexception [:message, :reason]

    @type t :: %__MODULE__{
            message: String.t(),
            reason: String.t() | nil
          }

    @impl true
    def exception(opts) when is_list(opts) do
      reason = Keyword.get(opts, :reason)

      message =
        opts[:message] ||
          "Execution cancelled" <>
            if(reason, do: ": #{reason}", else: "")

      %__MODULE__{
        message: message,
        reason: reason
      }
    end

    def exception(message) when is_binary(message) do
      %__MODULE__{message: message}
    end
  end
end
