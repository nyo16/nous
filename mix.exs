defmodule Yggdrasil.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/yourusername/exadantic"

  def project do
    [
      app: :yggdrasil,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      description: "Type-safe AI agent framework for Elixir with OpenAI-compatible models",
      source_url: @source_url,
      package: package(),
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: [
        plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
        plt_add_apps: [:mix]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Yggdrasil.Application, []},
      included_applications: [:gemini_ex]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # OpenAI client library
      {:openai_ex, "~> 0.9.17"},

      # Anthropic Claude client library
      {:anthropix, "~> 0.6.2"},

      # Google Gemini client library
      {:gemini_ex, github: "nshkrdotcom/gemini_ex"},

      # JSON
      {:jason, "~> 1.4"},

      # Validation
      {:ecto, "~> 3.11"},

      # HTTP client (required by openai_ex)
      {:finch, "~> 0.18"},

      # Telemetry
      {:telemetry, "~> 1.2"},

      # Dev/Test
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.1", only: :test}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "docs/QUICKSTART.md",
        "docs/SUCCESS.md",
        "docs/LOCAL_LLM_GUIDE.md",
        "docs/IMPLEMENTATION_GUIDE.md",
        "docs/PROJECT_STRUCTURE.md",
        "examples/README.md"
      ],
      source_ref: "v#{@version}",
      source_url: @source_url,
      groups_for_modules: [
        "Core": [
          Yggdrasil,
          Yggdrasil.Agent,
          Yggdrasil.AgentRunner
        ],
        "Data Types": [
          Yggdrasil.Types,
          Yggdrasil.Usage,
          Yggdrasil.RunContext
        ],
        "Models": [
          Yggdrasil.Model,
          Yggdrasil.ModelParser,
          Yggdrasil.Models.Behaviour,
          Yggdrasil.Models.OpenAICompatible
        ],
        "Tools": [
          Yggdrasil.Tool,
          Yggdrasil.ToolSchema,
          Yggdrasil.ToolExecutor
        ],
        "Messages": [
          Yggdrasil.Messages
        ],
        "Output": [
          Yggdrasil.Output
        ],
        "Infrastructure": [
          Yggdrasil.Application,
          Yggdrasil.Telemetry
        ],
        "Errors": [
          Yggdrasil.Errors
        ],
        "Testing": [
          Yggdrasil.Testing.MockModel,
          Yggdrasil.Testing.TestHelpers
        ]
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      }
    ]
  end
end
