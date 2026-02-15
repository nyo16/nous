defmodule Nous.MixProject do
  use Mix.Project

  @version "0.10.1"
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
      # JSON
      {:jason, "~> 1.4"},

      # YAML (for evaluation framework)
      {:yaml_elixir, "~> 2.9"},

      # Validation
      {:ecto, "~> 3.11"},

      # HTTP clients for all LLM providers
      {:finch, "~> 0.19"},
      {:req, "~> 0.5"},

      # HTML parsing (for web content extraction in research tools)
      {:floki, "~> 0.36", optional: true},

      # Telemetry
      {:telemetry, "~> 1.2"},

      # Note: For Prometheus metrics, users can add {:prom_ex, "~> 1.11"} and {:plug, "~> 1.18"}
      # to their deps. The Nous.PromEx.Plugin will automatically be available.

      # Dev/Test
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.1", only: :test},
      {:phoenix_pubsub, "~> 2.1", only: :test}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "CHANGELOG.md",

        # Getting Started
        {"docs/getting-started.md", filename: "getting_started", title: "Getting Started Guide"},

        # Examples Overview
        {"examples/README.md", filename: "examples_overview", title: "Examples Overview"},

        # Production Guides
        {"docs/guides/liveview-integration.md",
         filename: "liveview_integration", title: "Phoenix LiveView Integration"},
        {"docs/guides/best_practices.md",
         filename: "best_practices", title: "Production Best Practices"},
        {"docs/guides/tool_development.md",
         filename: "tool_development", title: "Tool Development Guide"},
        {"docs/guides/troubleshooting.md",
         filename: "troubleshooting", title: "Troubleshooting Guide"},
        {"docs/guides/migration_guide.md", filename: "migration_guide", title: "Migration Guide"},
        {"docs/guides/evaluation.md",
         filename: "evaluation", title: "Evaluation Framework Guide"},

        # Design Documents
        {"docs/design/llm_council_design.md",
         filename: "council_design", title: "LLM Council Design"}
      ],
      source_ref: "v#{@version}",
      source_url: @source_url,
      groups_for_extras: [
        "Getting Started": [
          "readme.html",
          "getting_started.html",
          "examples_overview.html"
        ],
        "Production Guides": [
          "liveview_integration.html",
          "best_practices.html",
          "tool_development.html",
          "troubleshooting.html",
          "migration_guide.html",
          "evaluation.html"
        ],
        Design: [
          "council_design.html"
        ]
      ],
      groups_for_modules: [
        "Core API": [
          Nous,
          Nous.Agent,
          Nous.Agent.Context,
          Nous.Agent.Behaviour,
          Nous.Agent.Callbacks,
          Nous.ReActAgent
        ],
        "Agent Implementations": [
          Nous.Agents.BasicAgent,
          Nous.Agents.ReActAgent
        ],
        "Agent Execution": [
          Nous.AgentRunner,
          Nous.AgentServer
        ],
        "Model Configuration": [
          Nous.Model,
          Nous.ModelDispatcher
        ],
        Providers: [
          Nous.Provider,
          Nous.Providers.HTTP,
          Nous.Providers.OpenAI,
          Nous.Providers.OpenAICompatible,
          Nous.Providers.Anthropic,
          Nous.Providers.LMStudio
        ],
        "Tool System": [
          Nous.Tool,
          Nous.Tool.Behaviour,
          Nous.Tool.ContextUpdate,
          Nous.Tool.Validator,
          Nous.ToolSchema,
          Nous.ToolExecutor
        ],
        Testing: [
          Nous.Tool.Testing
        ],
        Templates: [
          Nous.PromptTemplate
        ],
        "Data Types": [
          Nous.Types,
          Nous.Usage,
          Nous.Messages
        ],
        Infrastructure: [
          Nous.Telemetry,
          Nous.Errors
        ],
        Evaluation: [
          Nous.Eval,
          Nous.Eval.Suite,
          Nous.Eval.TestCase,
          Nous.Eval.Runner,
          Nous.Eval.Evaluator,
          Nous.Eval.Metrics,
          Nous.Eval.Reporter,
          Nous.Eval.Config
        ],
        "Plugin System": [
          Nous.Plugin,
          Nous.Plugins.HumanInTheLoop,
          Nous.Plugins.SubAgent,
          Nous.Plugins.Summarization
        ],
        PubSub: [
          Nous.PubSub,
          Nous.PubSub.Approval
        ],
        Persistence: [
          Nous.Persistence,
          Nous.Persistence.ETS
        ],
        Supervision: [
          Nous.AgentRegistry,
          Nous.AgentDynamicSupervisor
        ],
        Research: [
          Nous.Research,
          Nous.Research.Coordinator,
          Nous.Research.Planner,
          Nous.Research.Searcher,
          Nous.Research.Synthesizer,
          Nous.Research.Reporter,
          Nous.Research.Finding,
          Nous.Research.Report
        ],
        "Research Tools": [
          Nous.Tools.WebFetch,
          Nous.Tools.Summarize,
          Nous.Tools.SearchScrape,
          Nous.Tools.TavilySearch,
          Nous.Tools.ResearchNotes
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
