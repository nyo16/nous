defmodule Nous.MixProject do
  use Mix.Project

  @version "0.7.3"
  @source_url "https://github.com/nyo16/nous"

  def project do
    [
      app: :nous,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      aliases: aliases(),
      description: "AI agent framework for Elixir with multi-provider LLM support",
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
      mod: {Nous.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # OpenAI client library (optional)
      # To enable OpenAI-compatible providers, add {:openai_ex, "~> 0.9.17"} to your deps
      {:openai_ex, "~> 0.9.17", optional: true},

      # Anthropic Claude client library (optional)
      # To enable Anthropic support, add {:anthropix, "~> 0.6.2"} to your deps
      {:anthropix, "~> 0.6.2", optional: true},

      # Google Gemini client library (optional)
      # To enable Gemini support, add {:gemini_ex, "~> 0.8.1"} to your deps
      {:gemini_ex, "~> 0.8.1", optional: true},

      # JSON
      {:jason, "~> 1.4"},

      # Validation
      {:ecto, "~> 3.11"},

      # HTTP client (required by openai_ex)
      {:finch, "~> 0.18"},

      # HTTP client for Mistral API
      {:req, "~> 0.4"},

      # Telemetry
      {:telemetry, "~> 1.2"},

      # Note: For Prometheus metrics, users can add {:prom_ex, "~> 1.11"} and {:plug, "~> 1.18"}
      # to their deps. The Nous.PromEx.Plugin will automatically be available.

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

        # Getting Started
        {"docs/getting-started.md", filename: "getting_started", title: "Getting Started Guide"},

        # Examples and Tutorials
        {"examples/README.md", filename: "examples_overview", title: "Examples Overview"},
        {"examples/quickstart/README.md", filename: "quickstart", title: "5-Minute Quickstart"},

        # Learning Paths
        {"examples/tutorials/README.md", filename: "tutorials_overview", title: "Tutorial Overview"},
        {"examples/reference/README.md", filename: "reference_overview", title: "Reference Guide"},

        # Feature Guides
        {"examples/reference/tools.md", filename: "tools_reference", title: "Tools & Function Calling"},
        {"examples/reference/streaming.md", filename: "streaming_reference", title: "Streaming & Real-time"},
        {"examples/reference/providers.md", filename: "providers_reference", title: "Providers & Models"},
        {"examples/reference/patterns.md", filename: "patterns_reference", title: "Patterns & Architecture"},

        # Production Guides
        {"docs/guides/liveview-integration.md", filename: "liveview_integration", title: "Phoenix LiveView Integration"},
        {"docs/guides/best_practices.md", filename: "best_practices", title: "Production Best Practices"},
        {"docs/guides/tool_development.md", filename: "tool_development", title: "Tool Development Guide"},
        {"docs/guides/troubleshooting.md", filename: "troubleshooting", title: "Troubleshooting Guide"},
        {"docs/guides/migration_guide.md", filename: "migration_guide", title: "Migration Guide"},

        # Design Documents
        {"docs/design/llm_council_design.md", filename: "council_design", title: "LLM Council Design"}
      ],
      source_ref: "v#{@version}",
      source_url: @source_url,
      groups_for_modules: [
        "Core API": [
          Nous,
          Nous.Agent,
          Nous.ReActAgent
        ],
        "Agent Execution": [
          Nous.AgentRunner,
          Nous.AgentServer,
          Nous.RunContext
        ],
        "Model Providers": [
          Nous.Model,
          Nous.ModelParser,
          Nous.ModelDispatcher,
          Nous.Models.Behaviour,
          Nous.Models.OpenAICompatible,
          Nous.Models.Anthropic,
          Nous.Models.Gemini,
          Nous.Models.Mistral
        ],
        "Tool System": [
          Nous.Tool,
          Nous.ToolSchema,
          Nous.ToolExecutor
        ],
        "Built-in Tools": [
          Nous.Tools.BraveSearch,
          Nous.Tools.DateTimeTools,
          Nous.Tools.StringTools,
          Nous.Tools.TodoTools,
          Nous.Tools.ReActTools
        ],
        "Data Types": [
          Nous.Types,
          Nous.Usage,
          Nous.Messages
        ],
        "Infrastructure": [
          Nous.Telemetry,
          Nous.Errors
        ],
        "Integrations": [
          Nous.PromEx.Plugin
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

  defp aliases do
    [docs: ["docs", &copy_images/1]]
  end

  defp copy_images(_) do
    File.mkdir_p!("doc/images")
    File.cp!("images/header.jpeg", "doc/images/header.jpeg")
    File.cp!("images/logo.jpeg", "doc/images/logo.jpeg")
  end
end
