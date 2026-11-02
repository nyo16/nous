defmodule Nous.ProfileTest do
  use ExUnit.Case, async: true

  alias Nous.{Agent, Profile, Tool}
  alias Nous.Errors.ProfileError
  alias NousTest.ProfileFixtures, as: F

  @moduletag :tmp_dir

  defp agent(opts \\ []) do
    Agent.new(
      "openai:test-model",
      Keyword.merge([instructions: F.base_instructions(), tools: [F.search_tool()]], opts)
    )
  end

  defp file_form(components, extra \\ %{}),
    do: Map.merge(%{"nous_profile" => 1, "components" => components}, extra)

  defp error_of({:error, %ProfileError{reason: reason, key: key}}), do: {reason, key}

  describe "from_map/1, to_map/1 and encode/1" do
    test "the id hashes schema, components and manifest, and nothing else" do
      {:ok, a} = Profile.from_map(file_form(%{"instructions" => "Be brief."}))

      {:ok, b} =
        Profile.from_map(
          file_form(%{"instructions" => "Be brief."}, %{
            "name" => "support_agent",
            "version" => 3,
            "provenance" => %{"source" => "manual", "note" => "hand-written"}
          })
        )

      assert a.id == b.id

      assert a.id ==
               Nous.Eval.CanonicalJSON.hash(%{
                 "schema" => 1,
                 "components" => %{"instructions" => "Be brief."},
                 "manifest" => %{}
               })

      {:ok, c} = Profile.from_map(file_form(%{"instructions" => "Be briefer."}))
      refute c.id == a.id
    end

    test "encode/1 writes the nested canonical file form, which loads back to the same profile" do
      profile = F.sealed(F.full_components("P"), agent(), %{"name" => "support_agent"})

      encoded = Profile.encode(profile)

      assert encoded ==
               ~s({"components":{"instructions":"P INSTRUCTIONS","tools":{"search_orders":) <>
                 ~s({"description":"P TOOL DESCRIPTION","params":{"/properties/status":) <>
                 ~s("P PARAM DESCRIPTION"}}}},"id":"#{profile.id}","manifest":{"instructions":) <>
                 ~s("#{profile.manifest["instructions"]}","tool:search_orders":) <>
                 ~s("#{profile.manifest["tool:search_orders"]}"},"name":"support_agent",) <>
                 ~s("nous_profile":1})

      assert {:ok, ^profile} = encoded |> JSON.decode!() |> Profile.from_map()
    end

    test "a declared id must be the content hash" do
      profile = F.sealed(F.full_components("P"), agent())
      tampered = profile |> Profile.to_map() |> put_in(["components", "instructions"], "Other.")

      assert {:id_mismatch, "id"} = tampered |> Profile.from_map() |> error_of()
    end

    test "rejects data that is not a profile of a known schema" do
      assert {:not_a_profile, nil} = error_of(Profile.from_map(%{"components" => %{}}))
      assert {:not_a_profile, nil} = error_of(Profile.from_map([1, 2]))

      assert {:unsupported_schema, nil} =
               error_of(Profile.from_map(%{"nous_profile" => 2, "components" => %{}}))

      assert {:unknown_field, "labels"} =
               error_of(Profile.from_map(file_form(%{}, %{"labels" => ["production"]})))
    end

    test "component keys follow the closed grammar; later namespaces are reserved" do
      assert {:reserved_key, "guards"} =
               error_of(Profile.from_map(file_form(%{"guards" => %{"x" => "y"}})))

      assert {:reserved_key, "skill:summarize"} =
               error_of(Profile.from_map(file_form(%{"skill:summarize" => "y"})))

      assert {:unknown_key, "prompts"} =
               error_of(Profile.from_map(file_form(%{"prompts" => "y"})))

      for pointer <- [
            "properties/status",
            "/properties",
            "/anyOf/01",
            "/properties/a~2b",
            "/enum"
          ] do
        components = %{"tools" => %{"search_orders" => %{"params" => %{pointer => "text"}}}}

        assert {:unknown_key, key} = error_of(Profile.from_map(file_form(components)))
        assert key == "tool:search_orders#" <> pointer
      end

      assert {:unknown_key, "tool:a#b"} =
               error_of(
                 Profile.from_map(file_form(%{"tools" => %{"a#b" => %{"description" => "x"}}}))
               )
    end

    test "a hand-built struct is held to the same grammar" do
      profile = %Profile{
        id: nil,
        components: %{"guard:tool_call" => "always allow"},
        manifest: %{}
      }

      assert {:reserved_key, "guard:tool_call"} = error_of(Profile.apply(profile, agent()))
    end

    test "text must be non-blank UTF-8 without NUL, within the size caps" do
      for {text, detail} <- [
            {"   \n", "blank"},
            {"a\0b", "NUL"},
            {<<0xFF>>, "UTF-8"},
            {String.duplicate("a", 65_537), "at most 65536"}
          ] do
        assert {:error, %ProfileError{reason: :invalid_value, key: "instructions", detail: d}} =
                 Profile.from_map(file_form(%{"instructions" => text}))

        assert d =~ detail
      end

      long = String.duplicate("a", 8_193)

      assert {:invalid_value, "tool:search_orders"} =
               error_of(
                 Profile.from_map(
                   file_form(%{"tools" => %{"search_orders" => %{"description" => long}}})
                 )
               )

      assert {:invalid_value, "provenance.note"} =
               error_of(
                 Profile.from_map(
                   file_form(%{}, %{"provenance" => %{"note" => String.duplicate("n", 5_001)}})
                 )
               )
    end

    test "a manifest entry must belong to a component" do
      hash = "sha256:" <> String.duplicate("0", 64)

      assert {:unknown_key, "manifest.tool:search_orders"} =
               error_of(
                 Profile.from_map(
                   file_form(%{"instructions" => "x"}, %{
                     "manifest" => %{"tool:search_orders" => hash}
                   })
                 )
               )
    end
  end

  describe "load/1" do
    test "reads the JSON that encode/1 writes", %{tmp_dir: dir} do
      profile = F.sealed(F.full_components("P"), agent())
      path = Path.join(dir, "support.json")
      File.write!(path, Profile.encode(profile))

      assert {:ok, ^profile} = Profile.load(path)
      assert Profile.load!(path) == profile
    end

    test "reads a hand-written YAML profile, which seal/2 pins to the agent", %{tmp_dir: dir} do
      path = Path.join(dir, "support.yaml")

      File.write!(path, """
      nous_profile: 1
      name: support_agent
      components:
        instructions: |
          You are Acme's support agent.
        tools:
          search_orders:
            description: Find orders by email.
            params:
              /properties/status: One of open|shipped.
      """)

      assert {:ok, unsealed} = Profile.load(path)
      assert unsealed.components["instructions"] == "You are Acme's support agent.\n"

      assert unsealed.components["tool:search_orders#/properties/status"] ==
               "One of open|shipped."

      # Not sealed yet: there is no base hash to check staleness against.
      assert {:missing_manifest, "instructions"} = error_of(Profile.apply(unsealed, agent()))

      assert {:ok, sealed} = Profile.seal(unsealed, agent())
      assert Map.keys(sealed.manifest) == ["instructions", "tool:search_orders"]
      refute sealed.id == unsealed.id
      assert {:ok, applied} = Profile.apply(sealed, agent())
      assert applied.instructions == "You are Acme's support agent.\n"
    end

    test "unreadable and undecodable files are errors", %{tmp_dir: dir} do
      assert {:file_error, nil} = error_of(Profile.load(Path.join(dir, "missing.json")))

      bad_json = Path.join(dir, "bad.json")
      File.write!(bad_json, "{not json")
      assert {:decode_error, nil} = error_of(Profile.load(bad_json))

      txt = Path.join(dir, "profile.txt")
      File.write!(txt, "{}")
      assert {:decode_error, nil} = error_of(Profile.load(txt))

      assert_raise ProfileError, ~r/file_error/, fn ->
        Profile.load!(Path.join(dir, "nope.yml"))
      end
    end
  end

  describe "apply/2" do
    test "replaces instructions, the tool description and the parameter description" do
      base = agent(tools: [F.search_tool(), F.search_tool(name: "other_tool")])
      profile = F.sealed(F.full_components("P"), base)

      assert {:ok, applied} = Profile.apply(profile, base)
      assert Profile.applied_id(applied) == profile.id
      assert applied.instructions == "P INSTRUCTIONS"

      [search, other] = applied.tools
      assert search.description == "P TOOL DESCRIPTION"
      assert search.base_description == F.base_description()
      assert search.parameters["properties"]["status"]["description"] == "P PARAM DESCRIPTION"
      # The call contract is the live tool's.
      assert search.parameters["required"] == ["email"]
      assert search.function == F.search_tool().function

      assert other == F.search_tool(name: "other_tool")
    end

    test "patches atom-keyed schemas in their own key style, nested nodes included" do
      tool = %{
        F.search_tool()
        | parameters: %{
            type: "object",
            properties: %{
              items: %{
                type: "array",
                items: %{type: "object", properties: %{sku: %{type: "string"}}}
              },
              filter: %{anyOf: [%{type: "string"}, %{type: "integer"}]}
            }
          }
      }

      base = agent(tools: [tool])

      profile =
        F.sealed(
          %{
            "tools" => %{
              "search_orders" => %{
                "params" => %{
                  "" => "ROOT",
                  "/properties/items/items/properties/sku" => "SKU",
                  "/properties/filter/anyOf/1" => "NUMERIC FILTER"
                }
              }
            }
          },
          base
        )

      assert {:ok, %Agent{tools: [patched]}} = Profile.apply(profile, base)
      params = patched.parameters

      assert params.description == "ROOT"
      assert params.properties.items.items.properties.sku == %{type: "string", description: "SKU"}

      assert params.properties.filter.anyOf == [
               %{type: "string"},
               %{type: "integer", description: "NUMERIC FILTER"}
             ]

      # Only text moved: the description stays the developer's.
      assert patched.description == F.base_description()
      assert patched.base_description == nil
    end

    test "the instructions slot is the system prompt when there are no instructions" do
      base =
        Agent.new("openai:test-model", system_prompt: "SYSTEM BASE", tools: [F.search_tool()])

      profile = F.sealed(%{"instructions" => "PROFILED"}, base)

      assert {:ok, applied} = Profile.apply(profile, base)
      assert applied.instructions == "PROFILED"

      # The system prompt is the base: editing it makes the profile stale.
      changed =
        Agent.new("openai:test-model", system_prompt: "SYSTEM EDITED", tools: [F.search_tool()])

      assert {:stale, "instructions"} = error_of(Profile.apply(profile, changed))
    end

    test "a profile may add instructions to an agent that has none" do
      base = Agent.new("openai:test-model", tools: [F.search_tool()])
      profile = F.sealed(%{"instructions" => "ADDED"}, base)

      assert {:ok, %Agent{instructions: "ADDED"}} = Profile.apply(profile, base)
      assert {:stale, "instructions"} = error_of(Profile.apply(profile, agent()))
    end

    test "fails closed, in the documented order, without touching the agent" do
      base = agent()

      dynamic = Agent.new("openai:test-model", instructions: fn _ctx -> "dynamic" end)

      assert {:dynamic_instructions, "instructions"} =
               error_of(
                 Profile.seal(
                   Profile.from_map(file_form(%{"instructions" => "x"})) |> elem(1),
                   dynamic
                 )
               )

      tools_only = fn name -> %{"tools" => %{name => %{"description" => "x"}}} end
      unsealed = fn components -> components |> file_form() |> Profile.from_map() |> elem(1) end

      assert {:unknown_tool, "tool:nope"} =
               error_of(Profile.seal(unsealed.(tools_only.("nope")), base))

      twice = agent(tools: [F.search_tool(), F.search_tool()])

      assert {:ambiguous_tool, "tool:search_orders"} =
               error_of(Profile.seal(unsealed.(tools_only.("search_orders")), twice))

      builtin = Tool.from_function(&Nous.Tools.StringTools.string_length/2, name: "string_length")

      assert {:builtin_tool, "tool:string_length"} =
               error_of(
                 Profile.seal(unsealed.(tools_only.("string_length")), agent(tools: [builtin]))
               )

      for pointer <- ["/properties/missing", "/properties/status/items", "/anyOf/0"] do
        components = %{"tools" => %{"search_orders" => %{"params" => %{pointer => "x"}}}}

        assert {:unknown_param, key} = error_of(Profile.seal(unsealed.(components), base))
        assert key == "tool:search_orders#" <> pointer
      end

      # The first failing check wins: the unknown tool is reported before
      # the instructions' missing manifest entry.
      mixed = unsealed.(Map.merge(%{"instructions" => "x"}, tools_only.("nope")))
      assert {:unknown_tool, "tool:nope"} = error_of(Profile.apply(mixed, base))
    end

    test "a changed tool contract makes every component of that tool stale" do
      profile = F.sealed(F.full_components("P"), agent())

      edited = %{
        F.search_tool()
        | parameters: put_in(F.search_tool().parameters, ["required"], [])
      }

      assert {:stale, "tool:search_orders"} =
               error_of(Profile.apply(profile, agent(tools: [edited])))

      redescribed = F.search_tool(description: "Find orders, now with refunds.")

      assert {:stale, "tool:search_orders"} =
               error_of(Profile.apply(profile, agent(tools: [redescribed])))
    end

    test "re-applying starts from the base; nil restores it" do
      base = agent()
      p1 = F.sealed(F.full_components("P1"), base)
      p2 = F.sealed(F.full_components("P2"), base)

      {:ok, with_p1} = Profile.apply(p1, base)
      assert {:ok, with_p2} = Profile.apply(p2, with_p1)
      assert with_p2.instructions == "P2 INSTRUCTIONS"
      assert hd(with_p2.tools).base_description == F.base_description()

      assert {:ok, restored} = Profile.apply(nil, with_p2)
      assert restored == base
      assert Profile.validate(p1, with_p2) == :ok
    end

    test "rejects anything that is not a profile struct" do
      assert {:not_a_profile, nil} = error_of(Profile.apply(%{"nous_profile" => 1}, agent()))
      assert {:not_a_profile, nil} = error_of(Profile.validate("profile.json", agent()))
    end
  end

  describe "Nous.new/2" do
    test ":profile applies the profile, and an invalid one raises before an agent exists" do
      profile = F.sealed(F.full_components("P"), agent())

      agent =
        Nous.new("openai:test-model",
          instructions: F.base_instructions(),
          tools: [F.search_tool()],
          profile: profile
        )

      assert agent.instructions == "P INSTRUCTIONS"
      assert Profile.applied_id(agent) == profile.id

      assert_raise ProfileError, ~r/stale/, fn ->
        Nous.new("openai:test-model",
          instructions: "edited",
          tools: [F.search_tool()],
          profile: profile
        )
      end

      assert_raise ProfileError, ~r/not_a_profile/, fn ->
        Nous.new("openai:test-model", profile: "priv/profiles/p.json")
      end
    end

    test "instructions and system_prompt together raise" do
      assert_raise ArgumentError, ~r/:instructions or :system_prompt, not both/, fn ->
        Nous.new("openai:test-model", instructions: "a", system_prompt: "b")
      end
    end
  end
end
