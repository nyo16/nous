defmodule Nous.MixProject do
  use Mix.Project

  @version "0.14.3"
  @source_url "https://github.com/nyo16/nous"

  def project do
    [
      app: :nous,
      version: @version,
      elixir: "~> 1.18",
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
        plt_add_apps: [:mix, :ex_unit, :inets]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets],
      mod: {Nous.Application, []},
      # hackney's :default pool starts automatically when the :hackney
      # application starts; ensuring it's listed here is just defensive.
      included_applications: []
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # YAML (for evaluation framework)
      {:yaml_elixir, "~> 2.9"},

      # Validation
      {:ecto, "~> 3.11"},

      # HTTP clients for all LLM providers.
      # Finch/Req for non-streaming (one-shot requests, redirects, retries).
      # Hackney for SSE/long-streaming bodies — its `:async, :once` mode is
      # truly pull-based, so the consumer paces the producer and a slow
      # consumer can't OOM us via mailbox accumulation. (Finch.stream/5's
      # callback is push-based; a fast LLM + slow consumer = unbounded
      # mailbox growth — see review M-12.)
      {:finch, "~> 0.19"},
      {:req, "~> 0.5"},
      {:hackney, "~> 4.0"},

      # Google Cloud auth for Vertex AI (optional — add to your app's deps to unlock)
      {:goth, "~> 1.4", optional: true},

      # HTML parsing (for web content extraction in research tools)
      {:floki, "~> 0.36", optional: true},

      # Memory system store backends (all optional — add to your app's deps to unlock)
      # {:muninn, "~> 0.4", optional: true},
      # {:zvec, "~> 0.2", optional: true},
      # {:exqlite, "~> 0.27", optional: true},
      # {:duckdbex, "~> 0.3", optional: true},

      # Local LLM inference via llama.cpp NIFs (optional — add to your app's deps to unlock)
      # {:llama_cpp_ex, "~> 0.6.5", optional: true},

      # Memory system embedding providers (all optional — add to your app's deps to unlock)
      # {:bumblebee, "~> 0.6", optional: true},
      # {:exla, "~> 0.9", optional: true},

      # Process execution for command hooks
      {:net_runner, "~> 1.0.4"},

      # Telemetry
      {:telemetry, "~> 1.2"},

      # Note: For Prometheus metrics, users can add {:prom_ex, "~> 1.11"} and {:plug, "~> 1.18"}
      # to their deps. The Nous.PromEx.Plugin will automatically be available.

      # Dev/Test
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.1", only: :test},
      {:phoenix_pubsub, "~> 2.1", only: :test},
      # Bypass = in-test HTTP server for exercising the streaming pipeline
      # without hitting real LLM endpoints.
      {:bypass, "~> 2.1", only: :test}
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
        {"docs/guides/skills.md", filename: "skills", title: "Skills Guide"},
        {"docs/guides/hooks.md", filename: "hooks", title: "Hooks Guide"},
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
        {"docs/guides/structured_output.md",
         filename: "structured_output", title: "Structured Output Guide"},
        {"docs/guides/workflows.md", filename: "workflows", title: "Workflow Engine Guide"},
        {"docs/guides/memory.md", filename: "memory", title: "Memory System Guide"},
        {"docs/guides/context.md", filename: "context", title: "Context & Dependencies Guide"},
        {"docs/guides/knowledge_base.md",
         filename: "knowledge_base", title: "Knowledge Base Guide"},

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
          "skills.html",
          "hooks.html",
          "liveview_integration.html",
          "best_practices.html",
          "tool_development.html",
          "troubleshooting.html",
          "migration_guide.html",
          "evaluation.html",
          "structured_output.html",
          "workflows.html",
          "memory.html",
          "context.html",
          "knowledge_base.html"
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
          Nous.ReActAgent,
          Nous.Transcript
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
          Nous.Providers.LMStudio,
          Nous.Providers.VertexAI,
          Nous.Providers.LlamaCpp,
          Nous.StreamNormalizer.LlamaCpp
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
        "Hooks System": [
          Nous.Hook,
          Nous.Hook.Registry,
          Nous.Hook.Runner
        ],
        "Skills System": [
          Nous.Skill,
          Nous.Skill.Loader,
          Nous.Skill.Registry,
          Nous.Plugins.Skills,
          Nous.Skills.CodeReview,
          Nous.Skills.TestGen,
          Nous.Skills.Debug,
          Nous.Skills.Refactor,
          Nous.Skills.ExplainCode,
          Nous.Skills.CommitMessage,
          Nous.Skills.DocGen,
          Nous.Skills.SecurityScan,
          Nous.Skills.Architect,
          Nous.Skills.TaskBreakdown,
          Nous.Skills.PhoenixLiveView,
          Nous.Skills.EctoPatterns,
          Nous.Skills.OtpPatterns,
          Nous.Skills.ElixirTesting,
          Nous.Skills.ElixirIdioms,
          Nous.Skills.PythonFastAPI,
          Nous.Skills.PythonTesting,
          Nous.Skills.PythonTyping,
          Nous.Skills.PythonDataScience,
          Nous.Skills.PythonSecurity,
          Nous.Skills.PythonUv
        ],
        "Plugin System": [
          Nous.Plugin,
          Nous.Plugins.HumanInTheLoop,
          Nous.Plugins.InputGuard,
          Nous.Plugins.InputGuard.Strategy,
          Nous.Plugins.InputGuard.Result,
          Nous.Plugins.InputGuard.Policy,
          Nous.Plugins.InputGuard.Strategies.Pattern,
          Nous.Plugins.InputGuard.Strategies.LLMJudge,
          Nous.Plugins.InputGuard.Strategies.Semantic,
          Nous.Plugins.Memory,
          Nous.Plugins.SubAgent,
          Nous.Plugins.Summarization
        ],
        Memory: [
          Nous.Memory,
          Nous.Memory.Entry,
          Nous.Memory.Store,
          Nous.Memory.Store.ETS,
          Nous.Memory.Store.SQLite,
          Nous.Memory.Store.DuckDB,
          Nous.Memory.Store.Muninn,
          Nous.Memory.Store.Zvec,
          Nous.Memory.Store.Hybrid,
          Nous.Memory.Scoring,
          Nous.Memory.Search,
          Nous.Memory.Tools,
          Nous.Memory.Embedding,
          Nous.Memory.Embedding.Bumblebee,
          Nous.Memory.Embedding.OpenAI,
          Nous.Memory.Embedding.Local
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
        ],
        "Coding Tools": [
          Nous.Tools.Bash,
          Nous.Tools.FileRead,
          Nous.Tools.FileWrite,
          Nous.Tools.FileEdit,
          Nous.Tools.FileGlob,
          Nous.Tools.FileGrep
        ],
        Session: [
          Nous.Session.Config,
          Nous.Session.Guardrails
        ],
        Permissions: [
          Nous.Permissions,
          Nous.Permissions.Policy
        ],
        "Knowledge Base": [
          Nous.KnowledgeBase,
          Nous.KnowledgeBase.Entry,
          Nous.KnowledgeBase.Document,
          Nous.KnowledgeBase.Link,
          Nous.KnowledgeBase.Store,
          Nous.KnowledgeBase.Store.ETS,
          Nous.KnowledgeBase.Tools,
          Nous.KnowledgeBase.Workflows,
          Nous.KnowledgeBase.HealthReport,
          Nous.KnowledgeBase.Prompts,
          Nous.Plugins.KnowledgeBase,
          Nous.Agents.KnowledgeBaseAgent
        ],
        "Workflow Engine": [
          Nous.Workflow,
          Nous.Workflow.Graph,
          Nous.Workflow.Node,
          Nous.Workflow.Edge,
          Nous.Workflow.State,
          Nous.Workflow.Compiler,
          Nous.Workflow.Engine,
          Nous.Workflow.Engine.Executor,
          Nous.Workflow.Engine.ParallelExecutor,
          Nous.Workflow.Engine.StateMerger,
          Nous.Workflow.Mermaid,
          Nous.Workflow.Trace,
          Nous.Workflow.Checkpoint,
          Nous.Workflow.Checkpoint.Store,
          Nous.Workflow.Checkpoint.ETS,
          Nous.Workflow.Scratch,
          Nous.Workflow.Telemetry
        ]
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/master/CHANGELOG.md"
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
