defmodule Nous.Plugins.InputGuard.Strategies.Pattern do
  @moduledoc """
  Regex-based pattern matching strategy for detecting prompt injection and jailbreak attempts.

  Ships with default patterns for common injection techniques including instruction
  override, role reassignment, DAN jailbreaks, and prompt extraction attempts.

  > #### Best-effort, not authorization {: .warning}
  >
  > This strategy is **defense-in-depth**, not a security boundary. Regex
  > matching over natural language is trivially evaded — by synonyms,
  > rephrasing, leetspeak, whitespace/zero-width splitting, translation, or
  > encoding — and the default patterns only catch well-known phrasings.
  >
  > A `:safe` result means "no known-bad pattern matched", NOT "this input is
  > trusted". Never gate a security or authorization decision on it. Treat
  > retrieved/tool/user content as untrusted regardless of what this strategy
  > returns, and rely on real controls (sandboxing, permissions, output
  > validation) for actual enforcement.

  ## Configuration

    * `:patterns` — Full override of the default pattern list. Each entry is a
      `{regex, label}` tuple where `label` describes what the pattern detects.
    * `:extra_patterns` — Additional patterns to append to the defaults.
      Use this when you want to keep the built-in patterns and add your own.

  ## Examples

      # Use defaults
      {Nous.Plugins.InputGuard.Strategies.Pattern, []}

      # Add extra patterns
      {Nous.Plugins.InputGuard.Strategies.Pattern,
        extra_patterns: [
          {~r/sudo mode/i, "sudo mode attempt"}
        ]}

      # Full override
      {Nous.Plugins.InputGuard.Strategies.Pattern,
        patterns: [
          {~r/ignore all previous/i, "instruction override"}
        ]}

  """

  @behaviour Nous.Plugins.InputGuard.Strategy

  alias Nous.Plugins.InputGuard.Result

  @default_patterns [
    # Instruction override attempts
    {~r/ignore\s+(all\s+)?(previous|prior|above|earlier)\s+(instructions?|prompts?|rules?|directions?)/i,
     "instruction override"},
    {~r/disregard\s+(all\s+)?(previous|prior|above|earlier)\s+(instructions?|prompts?|rules?)/i,
     "instruction override"},
    {~r/forget\s+(all\s+)?(your\s+)?(previous|prior|above|earlier)\s+(instructions?|prompts?|rules?)/i,
     "instruction override"},

    # Role reassignment
    {~r/you\s+are\s+now\s+(a|an|the)\s+/i, "role reassignment"},
    {~r/act\s+as\s+(a|an|if\s+you\s+are)\s+/i, "role reassignment"},
    {~r/pretend\s+(you\s+are|to\s+be)\s+/i, "role reassignment"},
    {~r/from\s+now\s+on[,\s]+you\s+(are|will|should|must)/i, "role reassignment"},

    # DAN / jailbreak patterns
    {~r/\bDAN\b.*\bmode\b/i, "DAN jailbreak"},
    {~r/\bjailbreak(ed|ing)?\b/i, "jailbreak attempt"},
    {~r/developer\s+mode\s+(enabled|on|activated)/i, "developer mode jailbreak"},
    {~r/do\s+anything\s+now/i, "DAN jailbreak"},

    # Prompt extraction
    {~r/reveal\s+(your|the|system)\s+(system\s+)?(prompt|instructions?|rules?)/i,
     "prompt extraction"},
    {~r/show\s+me\s+(your|the)\s+(system\s+)?(prompt|instructions?)/i, "prompt extraction"},
    {~r/what\s+(are|is)\s+your\s+(system\s+)?(prompt|instructions?|rules?)/i,
     "prompt extraction"},
    {~r/repeat\s+(your|the)\s+(system\s+)?(prompt|instructions?|rules?)\s+(back|verbatim)/i,
     "prompt extraction"},

    # Encoding / obfuscation evasion
    {~r/base64[:\s]+(decode|encode)/i, "encoding evasion"},
    {~r/\[SYSTEM\]/i, "system tag injection"},
    {~r/<\|?(system|im_start|im_end)\|?>/i, "special token injection"}
  ]

  @impl true
  def check(input, config, _ctx) do
    patterns = resolve_patterns(config)

    case find_match(normalize(input), patterns) do
      nil ->
        {:ok, %Result{severity: :safe, strategy: __MODULE__}}

      {_regex, label} ->
        {:ok,
         %Result{
           severity: :blocked,
           reason: "Pattern matched: #{label}",
           strategy: __MODULE__,
           metadata: %{pattern_label: label}
         }}
    end
  end

  defp resolve_patterns(config) do
    case Keyword.get(config, :patterns) do
      nil ->
        extra = Keyword.get(config, :extra_patterns, [])
        @default_patterns ++ extra

      patterns ->
        patterns
    end
  end

  defp find_match(input, patterns) do
    Enum.find(patterns, fn {regex, _label} ->
      Regex.match?(regex, input)
    end)
  end

  # Defeat trivial Unicode evasion before matching: NFKC folds full-width /
  # compatibility homoglyphs to their ASCII form, and we strip zero-width and
  # bidi/format control characters that can split tokens (e.g. "ig​nore").
  defp normalize(input) when is_binary(input) do
    input
    |> String.normalize(:nfkc)
    |> String.replace(
      ~r/[\x{00AD}\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2060}-\x{2064}\x{FEFF}]/u,
      ""
    )
  end

  defp normalize(input), do: input
end
