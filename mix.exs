defmodule Yggdrasil.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/nyo16/yggdrasil"

  def project do
    [
      app: :yggdrasil,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      aliases: aliases(),
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

      # Note: For Prometheus metrics, users can add {:prom_ex, "~> 1.11"} and {:plug, "~> 1.18"}
      # to their deps. The Yggdrasil.PromEx.Plugin will automatically be available.

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
        "docs/llm_council_design.md",
        {"examples/README.md", filename: "examples_overview", title: "Examples Overview"},
        {"examples/DISTRIBUTED_AGENTS.md", filename: "distributed_agents", title: "Distributed Agents"},
        {"examples/LIVEVIEW_INTEGRATION.md", filename: "liveview_integration", title: "LiveView Integration"}
      ],
      source_ref: "v#{@version}",
      source_url: @source_url,
      groups_for_modules: [
        "Core API": [
          Yggdrasil,
          Yggdrasil.Agent,
          Yggdrasil.ReActAgent
        ],
        "Agent Execution": [
          Yggdrasil.AgentRunner,
          Yggdrasil.AgentServer,
          Yggdrasil.RunContext
        ],
        "Model Providers": [
          Yggdrasil.Model,
          Yggdrasil.ModelParser,
          Yggdrasil.ModelDispatcher,
          Yggdrasil.Models.Behaviour,
          Yggdrasil.Models.OpenAICompatible,
          Yggdrasil.Models.Anthropic,
          Yggdrasil.Models.Gemini
        ],
        "Tool System": [
          Yggdrasil.Tool,
          Yggdrasil.ToolSchema,
          Yggdrasil.ToolExecutor
        ],
        "Built-in Tools": [
          Yggdrasil.Tools.BraveSearch,
          Yggdrasil.Tools.DateTimeTools,
          Yggdrasil.Tools.StringTools,
          Yggdrasil.Tools.TodoTools,
          Yggdrasil.Tools.ReActTools
        ],
        "Data Types": [
          Yggdrasil.Types,
          Yggdrasil.Usage,
          Yggdrasil.Messages
        ],
        "Infrastructure": [
          Yggdrasil.Telemetry,
          Yggdrasil.Errors
        ],
        "Integrations": [
          Yggdrasil.PromEx.Plugin
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
