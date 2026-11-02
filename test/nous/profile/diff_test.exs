defmodule Nous.Profile.DiffTest do
  use ExUnit.Case, async: true

  alias Nous.{Agent, Profile, Tool}
  alias NousTest.ProfileFixtures, as: F

  describe "diff/2" do
    test "classifies keys and diffs changed text line by line" do
      before = %{
        "instructions" => "You are support.\nAnswer refund questions directly.\nBe brief.",
        "tool:search_orders" => "Find orders.",
        "tool:gone" => "Old tool text."
      }

      after_ = %{
        "instructions" =>
          "You are support.\nBefore any refund answer, call search_orders.\nQuote the status.\nBe brief.",
        "tool:search_orders" => "Find orders.",
        "tool:search_orders#/properties/status" => "One of open|shipped."
      }

      diff = Profile.diff(before, after_)

      assert diff.added == ["tool:search_orders#/properties/status"]
      assert diff.removed == ["tool:gone"]
      assert diff.changed == ["instructions"]
      assert diff.unchanged == ["tool:search_orders"]

      assert [instructions, gone, param] = diff.components
      assert %{key: "instructions", change: :changed} = instructions

      assert instructions.lines == [
               {:eq, "You are support."},
               {:del, "Answer refund questions directly."},
               {:ins, "Before any refund answer, call search_orders."},
               {:ins, "Quote the status."},
               {:eq, "Be brief."}
             ]

      assert {instructions.lines_added, instructions.lines_removed} == {2, 1}

      delta =
        String.length(after_["instructions"]) - String.length(before["instructions"])

      assert instructions.chars_delta == delta
      assert instructions.tokens_delta == round(delta / 4)

      assert %{key: "tool:gone", change: :removed, lines: [{:del, "Old tool text."}]} = gone
      assert gone.chars_delta == -14 and gone.tokens_delta == -4 and gone.after == nil

      assert %{change: :added, lines: [{:ins, "One of open|shipped."}], lines_added: 1} = param
      assert param.chars_delta == 20 and param.tokens_delta == 5
    end

    test "takes profiles or nil, and identical sides have no components" do
      agent = F.agent()
      profile = F.sealed(F.full_components("A"), agent)

      assert %{added: added, removed: [], changed: [], components: components} =
               Profile.diff(nil, profile)

      assert added == Enum.sort(Map.keys(profile.components))
      assert length(components) == 3

      assert %{components: [], unchanged: unchanged} = Profile.diff(profile, profile)
      assert unchanged == added

      assert %{removed: ^added} = Profile.diff(profile, nil)
    end

    test "counts characters (graphemes), not bytes, and handles CRLF line ends" do
      diff = Profile.diff(%{"instructions" => "a\r\nb"}, %{"instructions" => "a\nb\nçé"})

      # "a\r\nb" is 3 graphemes, "a\nb\nçé" 6.
      assert [%{lines: [{:eq, "a"}, {:eq, "b"}, {:ins, "çé"}], chars_delta: 3}] =
               diff.components
    end
  end

  describe "components/1" do
    test "a profile's components are its component map" do
      profile = F.sealed(F.full_components("A"), F.agent())
      assert Profile.components(profile) == profile.components
    end

    test "an agent's components are its addressable text, keyed like profile components" do
      nested =
        Tool.from_function(&F.search_orders/2,
          name: "create/ticket",
          description: "Create a ticket.",
          parameters: %{
            type: "object",
            description: "Ticket fields.",
            properties: %{
              items: %{
                type: "array",
                items: %{
                  "type" => "object",
                  "properties" => %{"sku~id" => %{"type" => "string", "description" => "SKU."}}
                }
              },
              mode: %{"anyOf" => [%{"type" => "string", "description" => "By name."}, %{}]}
            }
          }
        )

      no_description = F.search_tool(name: "silent", description: nil)
      duplicate = F.search_tool(name: "twice")

      agent =
        Agent.new("openai:test-model",
          instructions: "Base.",
          tools: [F.search_tool(), nested, no_description, duplicate, duplicate]
        )

      components = Profile.components(agent)

      assert components == %{
               "instructions" => "Base.",
               "tool:search_orders" => F.base_description(),
               "tool:search_orders#/properties/status" => F.base_param(),
               "tool:create/ticket" => "Create a ticket.",
               "tool:create/ticket#" => "Ticket fields.",
               "tool:create/ticket#/properties/items/items/properties/sku~0id" => "SKU.",
               "tool:create/ticket#/properties/mode/anyOf/0" => "By name.",
               "tool:silent#/properties/status" => F.base_param()
             }

      # Every key is one a profile can address on this agent.
      {:ok, profile} =
        components
        |> Map.delete("tool:silent#/properties/status")
        |> then(&%Profile{id: nil, components: &1, manifest: %{}})
        |> Profile.seal(agent)

      assert :ok = Profile.validate(profile, agent)
    end

    test "an agent running a profile reports the profile's text; dynamic instructions none" do
      agent = F.agent()
      profile = F.sealed(F.full_components("NEW"), agent)
      patched = Profile.apply!(profile, agent)

      assert %{
               "instructions" => "NEW INSTRUCTIONS",
               "tool:search_orders" => "NEW TOOL DESCRIPTION"
             } =
               Profile.components(patched)

      assert Profile.components(Profile.apply!(nil, patched)) == Profile.components(agent)

      dynamic = Agent.new("openai:test-model", instructions: fn _ctx -> "x" end)
      assert Profile.components(dynamic) == %{}
    end
  end
end
