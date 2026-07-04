defmodule Nous.Errors do
  @moduledoc """
  Custom error types for Nous AI.

  These exceptions provide structured error information for different
  failure scenarios in agent execution.

  Every exception accepts either a keyword list of fields (with an optional
  `:message` override) or a bare message string; construction is shared via
  `Nous.Errors.Base`.
  """

  defmodule ConfigurationError do
    @moduledoc """
    Error in configuration or missing dependencies.

    Raised when required configuration is missing or a required
    optional dependency is not available.
    """

    use Nous.Errors.Base, fields: [:details]

    @type t :: %__MODULE__{
            message: String.t(),
            details: any()
          }

    defp default_message(_fields), do: "Configuration error"
  end

  defmodule ModelError do
    @moduledoc """
    Error from the model provider API.

    Raised when the underlying model API returns an error.

    Note: Consider using `ProviderError` for new code.
    """

    use Nous.Errors.Base, fields: [:provider, :status_code, :details]

    @type t :: %__MODULE__{
            message: String.t(),
            provider: atom() | nil,
            status_code: integer() | nil,
            details: any()
          }

    defp default_message(%{provider: provider, status_code: status_code}) do
      "Model request failed" <>
        if(provider, do: " (#{provider})", else: "") <>
        if(status_code, do: " [#{status_code}]", else: "")
    end
  end

  defmodule ProviderError do
    @moduledoc """
    Error from an LLM provider.

    Raised when a provider API call fails.

    ## Fields

      * `:provider` — provider id atom (e.g., `:vertex_ai`)
      * `:status_code` — HTTP status when applicable
      * `:retry_after_ms` — server-suggested backoff in milliseconds, parsed
        from the response body (`google.rpc.RetryInfo`) or `Retry-After`
        header. `nil` when the failure is not retry-hinted (e.g. daily quota
        exhaustion deliberately omits `RetryInfo` per Google's spec).
      * `:details` — raw error payload from the HTTP layer
    """

    use Nous.Errors.Base, fields: [:provider, :status_code, :retry_after_ms, :details]

    @type t :: %__MODULE__{
            message: String.t(),
            provider: atom() | nil,
            status_code: integer() | nil,
            retry_after_ms: pos_integer() | nil,
            details: any()
          }

    defp default_message(%{provider: provider, status_code: status_code}) do
      "Provider request failed" <>
        if(provider, do: " (#{provider})", else: "") <>
        if(status_code, do: " [#{status_code}]", else: "")
    end
  end

  defmodule ToolError do
    @moduledoc """
    Error during tool execution.

    Raised when a tool function fails during execution.
    """

    use Nous.Errors.Base, fields: [:tool_name, :attempt, :original_error]

    @type t :: %__MODULE__{
            message: String.t(),
            tool_name: String.t() | nil,
            attempt: non_neg_integer() | nil,
            original_error: any()
          }

    defp default_message(%{tool_name: tool_name, attempt: attempt}) do
      "Tool execution failed" <>
        if(tool_name, do: " (#{tool_name})", else: "") <>
        if(attempt, do: " after #{attempt} attempt(s)", else: "")
    end
  end

  defmodule ToolTimeout do
    @moduledoc """
    Error when a tool execution times out.

    Raised when a tool takes longer than its configured timeout.
    """

    use Nous.Errors.Base, fields: [:tool_name, :timeout]

    @type t :: %__MODULE__{
            message: String.t(),
            tool_name: String.t() | nil,
            timeout: non_neg_integer() | nil
          }

    defp default_message(%{tool_name: tool_name, timeout: timeout}) do
      "Tool '#{tool_name || "unknown"}' timed out after #{timeout || 0}ms"
    end
  end

  defmodule ValidationError do
    @moduledoc """
    Error during output validation.

    Raised when structured output fails Ecto validation.
    """

    use Nous.Errors.Base, fields: [:errors, :output_type]

    @type t :: %__MODULE__{
            message: String.t(),
            errors: keyword() | nil,
            output_type: module() | nil
          }

    defp default_message(%{output_type: output_type}) do
      "Output validation failed" <>
        if(output_type, do: " for #{inspect(output_type)}", else: "")
    end
  end

  defmodule UsageLimitExceeded do
    @moduledoc """
    Error when usage limits are exceeded.

    Raised when an agent run exceeds configured limits for
    requests, tokens, or tool calls.
    """

    use Nous.Errors.Base, fields: [:limit_type, :limit_value, :actual_value]

    @type t :: %__MODULE__{
            message: String.t(),
            limit_type: atom() | nil,
            limit_value: integer() | nil,
            actual_value: integer() | nil
          }

    defp default_message(%{
           limit_type: limit_type,
           limit_value: limit_value,
           actual_value: actual_value
         }) do
      "Usage limit exceeded" <>
        if(limit_type, do: " (#{limit_type})", else: "") <>
        if(limit_value && actual_value,
          do: ": #{actual_value} > #{limit_value}",
          else: ""
        )
    end
  end

  defmodule MaxIterationsExceeded do
    @moduledoc """
    Error when agent loop exceeds maximum iterations.

    Raised when an agent makes too many back-and-forth calls
    with the model, possibly indicating an infinite loop.
    """

    use Nous.Errors.Base, fields: [:max_iterations]

    @type t :: %__MODULE__{
            message: String.t(),
            max_iterations: pos_integer() | nil
          }

    defp default_message(%{max_iterations: max_iterations}) do
      "Maximum iterations exceeded" <>
        if(max_iterations, do: " (#{max_iterations})", else: "")
    end
  end

  defmodule ExecutionCancelled do
    @moduledoc """
    Error when agent execution is cancelled.

    Raised when an agent execution is explicitly cancelled
    by the user or system.
    """

    use Nous.Errors.Base, fields: [:reason]

    @type t :: %__MODULE__{
            message: String.t(),
            reason: String.t() | nil
          }

    defp default_message(%{reason: reason}) do
      "Execution cancelled" <>
        if(reason, do: ": #{reason}", else: "")
    end
  end
end
