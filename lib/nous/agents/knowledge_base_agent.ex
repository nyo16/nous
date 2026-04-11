defmodule Nous.Agents.KnowledgeBaseAgent do
  @moduledoc """
  Knowledge Base Agent behaviour implementation.

  Specializes agents for knowledge base curation: ingesting documents,
  compiling wiki entries, querying, generating outputs, and maintaining
  the knowledge base.

  Adds KB reasoning tools on top of the standard KB plugin tools:
  - `kb_plan_compilation` — Plan which entries to create from documents
  - `kb_verify_entry` — Cross-check an entry against source documents
  - `kb_suggest_links` — Suggest links between entries
  - `kb_summarize_topic` — Synthesize across multiple entries

  ## Example

      agent = Agent.new("openai:gpt-4",
        behaviour_module: Nous.Agents.KnowledgeBaseAgent,
        plugins: [Nous.Plugins.KnowledgeBase],
        deps: %{kb_config: %{store: Nous.KnowledgeBase.Store.ETS, kb_id: "my_kb"}}
      )

      {:ok, result} = Agent.run(agent, "Ingest this article about GenServers: ...")
      {:ok, result} = Agent.run(agent, "What do we know about OTP?")
      {:ok, result} = Agent.run(agent, "Generate a report on Elixir patterns")
  """

  @behaviour Nous.Agent.Behaviour

  alias Nous.{Message, Tool}
  alias Nous.Agent.Context

  @kb_system_prompt """
  You are a Knowledge Base curator and analyst. Your primary role is to maintain \
  a structured wiki-style knowledge base.

  ## Capabilities

  1. **INGEST**: Accept raw documents and add them to the knowledge base using `kb_ingest`.
  2. **COMPILE**: Transform raw content into structured wiki entries with `kb_add_entry`. \
  Include summaries, concepts, tags, and use [[slug]] format for wiki-links between entries.
  3. **QUERY**: Search and retrieve information using `kb_search` and `kb_read`. \
  Always search the knowledge base before answering questions.
  4. **GENERATE**: Produce reports, summaries, and slide decks using `kb_generate`.
  5. **MAINTAIN**: Audit entries using `kb_health_check`, create links with `kb_link`, \
  and check backlinks with `kb_backlinks`.

  ## Reasoning Tools

  - `kb_plan_compilation` — Before compiling, plan which entries to create
  - `kb_verify_entry` — Cross-check an entry against its sources
  - `kb_suggest_links` — Analyze entries and suggest connections
  - `kb_summarize_topic` — Synthesize information across multiple entries

  ## Wiki Link Format

  Use [[slug]] to link between entries. Example: [[elixir-genserver]]

  ## Guidelines

  - Always cite which knowledge base entries you used in your answer
  - When ingesting documents, plan the compilation first, then create entries
  - Proactively suggest improvements when you notice gaps or inconsistencies
  - Prefer updating existing entries over creating duplicates
  """

  @impl true
  def init_context(_agent, ctx) do
    ctx
    |> Context.merge_deps(%{
      kb_operations: Map.get(ctx.deps, :kb_operations, []),
      kb_compile_queue: Map.get(ctx.deps, :kb_compile_queue, [])
    })
  end

  @impl true
  def build_messages(agent, ctx) do
    system_prompt = build_kb_system_prompt(agent, ctx)
    non_system_messages = Enum.reject(ctx.messages, &Message.is_system?/1)
    [Message.system(system_prompt) | non_system_messages]
  end

  @impl true
  def process_response(_agent, response, ctx) do
    ctx = Context.add_message(ctx, response)

    # Track KB operations for reporting
    tool_calls = response.tool_calls || []

    kb_calls =
      Enum.filter(tool_calls, fn call ->
        name = call["name"] || call[:name] || ""
        String.starts_with?(to_string(name), "kb_")
      end)

    if kb_calls != [] do
      ops = ctx.deps[:kb_operations] || []

      new_ops =
        Enum.map(kb_calls, fn call ->
          %{tool: call["name"] || call[:name], timestamp: DateTime.utc_now()}
        end)

      Context.merge_deps(ctx, %{kb_operations: ops ++ new_ops})
    else
      ctx
    end
  end

  @impl true
  def extract_output(agent, ctx) do
    Nous.Agents.BasicAgent.extract_output(agent, ctx)
  end

  @impl true
  def get_tools(agent) do
    kb_reasoning_tools() ++ agent.tools
  end

  # ---------------------------------------------------------------------------
  # KB Reasoning Tools
  # ---------------------------------------------------------------------------

  defp kb_reasoning_tools do
    [
      plan_compilation_tool(),
      verify_entry_tool(),
      suggest_links_tool(),
      summarize_topic_tool()
    ]
  end

  defp plan_compilation_tool do
    %Tool{
      name: "kb_plan_compilation",
      description:
        "Plan which wiki entries to create from a set of documents. " <>
          "Call this before compiling to organize your approach.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "document_summaries" => %{
            "type" => "string",
            "description" => "Brief summary of the documents to compile"
          },
          "planned_entries" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "title" => %{"type" => "string"},
                "concepts" => %{
                  "type" => "array",
                  "items" => %{"type" => "string"}
                },
                "rationale" => %{"type" => "string"}
              }
            },
            "description" => "List of planned entries with titles, concepts, and rationale"
          }
        },
        "required" => ["document_summaries", "planned_entries"]
      },
      function: fn _ctx, args ->
        {:ok,
         %{
           status: "plan_recorded",
           document_summaries: args["document_summaries"],
           planned_entries: args["planned_entries"],
           message: "Compilation plan recorded. Proceed to create entries with kb_add_entry."
         }}
      end,
      takes_ctx: true,
      category: :execute
    }
  end

  defp verify_entry_tool do
    %Tool{
      name: "kb_verify_entry",
      description:
        "Cross-check a wiki entry against its source documents. " <>
          "Record whether the entry accurately represents its sources.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "entry_slug" => %{
            "type" => "string",
            "description" => "Slug of the entry to verify"
          },
          "verification_notes" => %{
            "type" => "string",
            "description" => "Your assessment of accuracy and completeness"
          },
          "confidence" => %{
            "type" => "number",
            "description" => "Updated confidence score (0.0-1.0)"
          },
          "issues" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Any issues found"
          }
        },
        "required" => ["entry_slug", "verification_notes", "confidence"]
      },
      function: fn _ctx, args ->
        {:ok,
         %{
           status: "verified",
           entry_slug: args["entry_slug"],
           confidence: args["confidence"],
           issues: args["issues"] || [],
           notes: args["verification_notes"]
         }}
      end,
      takes_ctx: true,
      category: :execute
    }
  end

  defp suggest_links_tool do
    %Tool{
      name: "kb_suggest_links",
      description:
        "Analyze entries and suggest links between them based on content overlap and conceptual connections.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "suggestions" => %{
            "type" => "array",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "from_slug" => %{"type" => "string"},
                "to_slug" => %{"type" => "string"},
                "link_type" => %{"type" => "string"},
                "rationale" => %{"type" => "string"}
              }
            },
            "description" => "Suggested links with rationale"
          }
        },
        "required" => ["suggestions"]
      },
      function: fn _ctx, args ->
        suggestions = args["suggestions"] || []

        {:ok,
         %{
           status: "suggestions_recorded",
           count: length(suggestions),
           suggestions: suggestions,
           message: "Use kb_link to create the suggested links."
         }}
      end,
      takes_ctx: true,
      category: :execute
    }
  end

  defp summarize_topic_tool do
    %Tool{
      name: "kb_summarize_topic",
      description:
        "Synthesize information across multiple entries on a topic into a coherent summary.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "topic" => %{
            "type" => "string",
            "description" => "Topic to summarize"
          },
          "entry_slugs" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Slugs of entries consulted"
          },
          "summary" => %{
            "type" => "string",
            "description" => "Synthesized summary"
          },
          "key_points" => %{
            "type" => "array",
            "items" => %{"type" => "string"},
            "description" => "Key points extracted"
          }
        },
        "required" => ["topic", "entry_slugs", "summary"]
      },
      function: fn _ctx, args ->
        {:ok,
         %{
           status: "summarized",
           topic: args["topic"],
           entries_consulted: args["entry_slugs"],
           summary: args["summary"],
           key_points: args["key_points"] || []
         }}
      end,
      takes_ctx: true,
      category: :execute
    }
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp build_kb_system_prompt(agent, _ctx) do
    base = @kb_system_prompt

    if agent.instructions do
      instructions =
        if is_function(agent.instructions, 0),
          do: agent.instructions.(),
          else: agent.instructions

      "#{instructions}\n\n#{base}"
    else
      base
    end
  end
end
