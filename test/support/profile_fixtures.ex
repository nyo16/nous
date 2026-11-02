defmodule NousTest.ProfileFixtures do
  @moduledoc false
  # Agents, tools and profiles for the `Nous.Profile` tests. The module sits
  # outside the `Nous` namespace on purpose: a profile refuses tools whose
  # function is defined under `Nous` (built-in tools), and test modules are
  # all named `Nous.*Test`.

  alias Nous.{Profile, Tool}

  @base_instructions "BASE INSTRUCTIONS: answer politely."
  @base_description "BASE TOOL DESCRIPTION: find orders."
  @base_param "BASE PARAM: the order status."

  def base_instructions, do: @base_instructions
  def base_description, do: @base_description
  def base_param, do: @base_param

  # The tool body. Reports to `deps[:profile_test_pid]` when there is one.
  def search_orders(ctx, args) do
    if pid = ctx.deps[:profile_test_pid], do: send(pid, {:tool_ran, args})
    "order 42: shipped"
  end

  def search_tool(opts \\ []) do
    Tool.from_function(&__MODULE__.search_orders/2,
      name: Keyword.get(opts, :name, "search_orders"),
      description: Keyword.get(opts, :description, @base_description),
      category: :read,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "status" => %{"type" => "string", "description" => @base_param},
          "email" => %{"type" => "string"}
        },
        "required" => ["email"]
      }
    )
  end

  # Agent factories for the `mix nous.profile.*` tasks (`--agent Mod.fun`).
  def agent, do: build_agent(@base_instructions, [search_tool()])

  def edited_agent,
    do: build_agent("EDITED BASE INSTRUCTIONS: answer politely and briefly.", [search_tool()])

  def toolless_agent, do: build_agent(@base_instructions, [])
  def not_an_agent, do: :not_an_agent
  def raising_agent, do: raise("agent factory is down")

  defp build_agent(instructions, tools),
    do: Nous.Agent.new("openai:test-model", instructions: instructions, tools: tools)

  # `components` in the file form (`"instructions"`, `"tools"`), sealed
  # against `agent`.
  def sealed(components, agent, extra \\ %{}) do
    {:ok, profile} =
      %{"nous_profile" => 1, "components" => components}
      |> Map.merge(extra)
      |> Profile.from_map()

    {:ok, profile} = Profile.seal(profile, agent)
    profile
  end

  # The usual profile: new instructions, tool description and one parameter
  # description, all tagged with `tag` so each test can tell them apart.
  def full_components(tag) do
    %{
      "instructions" => "#{tag} INSTRUCTIONS",
      "tools" => %{
        "search_orders" => %{
          "description" => "#{tag} TOOL DESCRIPTION",
          "params" => %{"/properties/status" => "#{tag} PARAM DESCRIPTION"}
        }
      }
    }
  end
end
