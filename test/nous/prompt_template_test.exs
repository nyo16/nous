defmodule Nous.PromptTemplateTest do
  use ExUnit.Case, async: true

  alias Nous.PromptTemplate
  alias Nous.Message

  describe "from_template/2 safety" do
    test "accepts plain text with no substitutions" do
      assert %PromptTemplate{} = PromptTemplate.from_template("hello world")
    end

    test "accepts simple <%= @var %> substitution" do
      assert %PromptTemplate{} = PromptTemplate.from_template("Hello, <%= @name %>!")
    end

    test "accepts multiple substitutions and surrounding whitespace" do
      template =
        PromptTemplate.from_template("<%= @greeting %>, <%=@name%> - <%=  @signoff   %>!")

      assert template.text =~ "@greeting"
    end

    test "rejects EEx code-execution expressions (System.cmd)" do
      assert_raise ArgumentError, ~r/unsupported <%/, fn ->
        PromptTemplate.from_template("<%= System.cmd(\"rm\", [\"-rf\", \"/\"]) %>")
      end
    end

    test "rejects EEx control flow (if/end blocks)" do
      assert_raise ArgumentError, ~r/unsupported <%/, fn ->
        PromptTemplate.from_template("<% if @x do %>yes<% end %>")
      end
    end

    test "rejects bare <% %> (no =)" do
      assert_raise ArgumentError, ~r/unsupported <%/, fn ->
        PromptTemplate.from_template("<% foo %>")
      end
    end

    test "rejects @var followed by code (e.g. @var.field)" do
      # @name.field is NOT a valid simple <%= @ident %> match; reject it.
      assert_raise ArgumentError, ~r/unsupported <%/, fn ->
        PromptTemplate.from_template("<%= @name.upcase %>")
      end
    end
  end

  describe "format/2 substitution" do
    test "substitutes atom-keyed bindings" do
      template = PromptTemplate.from_template("Hello, <%= @name %>!")
      assert PromptTemplate.format(template, %{name: "Alice"}) == "Hello, Alice!"
    end

    test "substitutes string-keyed bindings as a fallback" do
      template = PromptTemplate.from_template("Hello, <%= @name %>!")
      assert PromptTemplate.format(template, %{"name" => "Alice"}) == "Hello, Alice!"
    end

    test "leaves placeholder when binding is missing" do
      template = PromptTemplate.from_template("Hello, <%= @name %>!")
      assert PromptTemplate.format(template, %{}) == "Hello, <%= @name %>!"
    end

    test "merges template :inputs defaults with bindings" do
      template =
        PromptTemplate.from_template("<%= @greeting %>, <%= @name %>!", inputs: %{greeting: "Hi"})

      assert PromptTemplate.format(template, %{name: "Bob"}) == "Hi, Bob!"
    end

    test "to_string converts non-binary values" do
      template = PromptTemplate.from_template("count = <%= @n %>")
      assert PromptTemplate.format(template, %{n: 42}) == "count = 42"
    end
  end

  describe "to_message/2" do
    test "produces a Message with the template's role" do
      template = PromptTemplate.system("You are a <%= @persona %>.")
      msg = PromptTemplate.to_message(template, %{persona: "historian"})
      assert %Message{role: :system, content: "You are a historian."} = msg
    end
  end

  describe "extract_variables/1" do
    test "reuses an existing atom and never mints a new one" do
      # The contract is AGENTS.md invariant #1: a template body is untrusted
      # input, so extraction may reuse an existing atom but must never create
      # one. The old assertion (`is_atom(v) or is_binary(v)`) holds for any
      # return value the function could possibly produce, including the one
      # this test exists to forbid.
      novel = "nous_never_an_atom_#{System.unique_integer([:positive])}"

      assert [:role, ^novel] =
               PromptTemplate.extract_variables("Hello <%= @role %> from <%= @#{novel} %>")

      # The effect, not the return value: the atom table is unchanged.
      assert_raise ArgumentError, fn -> String.to_existing_atom(novel) end
    end

    test "deduplicates" do
      vars = PromptTemplate.extract_variables("<%= @x %> + <%= @x %>")
      assert length(vars) == 1
    end
  end

  describe "security: untrusted template body cannot execute Elixir" do
    @tag :tmp_dir
    test "format on a hostile template body never invokes EEx", %{tmp_dir: tmp_dir} do
      # If from_template/2 had let this through, EEx.eval_string would execute
      # File.write!/2. Since from_template rejects it, no execution happens.
      # Using @tag :tmp_dir gives a unique async-safe path per test, so this
      # test can stay parallel and won't leak a sentinel under /tmp.
      canary = Path.join(tmp_dir, "nous_pwn_canary")
      hostile = ~s{<%= File.write!(#{inspect(canary)}, "x") %>}

      assert_raise ArgumentError, fn ->
        PromptTemplate.from_template(hostile)
      end

      refute File.exists?(canary)
    end
  end

  describe "system/2, user/2, assistant/2" do
    test "set the role and carry :inputs through" do
      assert %PromptTemplate{role: :system, text: "a <%= @x %>", inputs: %{x: 1}} =
               PromptTemplate.system("a <%= @x %>", inputs: %{x: 1})

      assert %PromptTemplate{role: :user} = PromptTemplate.user("b")
      assert %PromptTemplate{role: :assistant} = PromptTemplate.assistant("c")
    end

    test "the role is not overridable through opts" do
      # Keyword.put/3, not put_new/3: system/2 always yields a :system template
      # even if a caller passes a conflicting :role.
      assert %PromptTemplate{role: :system} = PromptTemplate.system("x", role: :user)
      assert %PromptTemplate{role: :user} = PromptTemplate.user("x", role: :system)
      assert %PromptTemplate{role: :assistant} = PromptTemplate.assistant("x", role: :user)
    end

    test "all three inherit from_template/2's EEx rejection" do
      for fun <- [&PromptTemplate.system/1, &PromptTemplate.user/1, &PromptTemplate.assistant/1] do
        assert_raise ArgumentError, ~r/unsupported <%/, fn -> fun.("<% File.cwd!() %>") end
      end
    end
  end

  # format_string/2 is the ONE public entry point that never runs
  # validate_template_safety/1 — it hands the raw string straight to
  # do_format/2. Its safety therefore rests entirely on do_format/2 being a
  # Regex.replace over `<%= @ident %>` and nothing more. These tests pin that:
  # swapping do_format/2 for EEx.eval_string/2 fails every one of them.
  describe "format_string/2" do
    test "substitutes atom- and string-keyed bindings" do
      assert PromptTemplate.format_string("Hello, <%= @name %>!", %{name: "Ada"}) == "Hello, Ada!"
      assert PromptTemplate.format_string("<%= @name %>", %{"name" => "Ada"}) == "Ada"
    end

    test "leaves unbound placeholders in place" do
      assert PromptTemplate.format_string("<%= @a %>/<%= @b %>", %{a: "x"}) == "x/<%= @b %>"
    end

    test "does not evaluate a bare <% %> block" do
      hostile = "before <% System.halt() %> after"
      assert PromptTemplate.format_string(hostile, %{}) == hostile
    end

    test "does not evaluate an <%= %> expression that is not a bare @var" do
      hostile = ~s{<%= System.cmd("id", []) %>}
      assert PromptTemplate.format_string(hostile, %{}) == hostile
    end

    @tag :tmp_dir
    test "filesystem canary: a hostile body writes nothing", %{tmp_dir: tmp_dir} do
      canary = Path.join(tmp_dir, "format_string_canary")
      hostile = ~s{<%= File.write!(#{inspect(canary)}, "x") %>}

      assert PromptTemplate.format_string(hostile, %{}) == hostile
      refute File.exists?(canary)
    end
  end

  describe "build_messages/2" do
    test "builds one Message per {role, text} tuple with shared bindings" do
      assert [
               %Message{role: :system, content: "You are a helpful assistant"},
               %Message{role: :user, content: "I am Alice"}
             ] =
               PromptTemplate.build_messages(
                 [
                   {:system, "You are a <%= @kind %> assistant"},
                   {:user, "I am <%= @name %>"}
                 ],
                 %{kind: "helpful", name: "Alice"}
               )
    end

    test "rejects a hostile body rather than passing it through" do
      # Unlike format_string/2, build_messages/2 routes every text through
      # from_template/2, so it inherits validate_template_safety/1. Dropping
      # that call turns this raise into a silent pass-through.
      assert_raise ArgumentError, ~r/unsupported <%/, fn ->
        PromptTemplate.build_messages([{:system, "<% File.cwd!() %>"}], %{})
      end
    end

    @tag :tmp_dir
    test "filesystem canary: the rejected body never executes", %{tmp_dir: tmp_dir} do
      canary = Path.join(tmp_dir, "build_messages_canary")

      assert_raise ArgumentError, fn ->
        PromptTemplate.build_messages(
          [{:user, ~s{<%= File.write!(#{inspect(canary)}, "x") %>}}],
          %{}
        )
      end

      refute File.exists?(canary)
    end
  end

  describe "to_messages/2" do
    test "formats templates and passes existing Messages through untouched" do
      # The pin on `passthrough` is the contract: a %Message{} is NOT run
      # through format/2, so its literal `<%= @name %>` must survive even
      # though :name is bound.
      passthrough = Message.user("Hello <%= @name %>")

      assert [
               %Message{role: :system, content: "You are a historian"},
               ^passthrough,
               %Message{role: :user, content: "Tell me about Rome"}
             ] =
               PromptTemplate.to_messages(
                 [
                   PromptTemplate.system("You are a <%= @persona %>"),
                   passthrough,
                   PromptTemplate.user("Tell me about <%= @topic %>")
                 ],
                 %{persona: "historian", topic: "Rome", name: "Ada"}
               )
    end
  end

  describe "variables/1" do
    test "returns the template's variables, deduplicated and in order" do
      template = PromptTemplate.from_template("<%= @name %>/<%= @name %>/<%= @topic %>")
      assert PromptTemplate.variables(template) == [:name, :topic]
    end

    test "reads the template text, not its :inputs" do
      template = PromptTemplate.from_template("<%= @greeting %>", inputs: %{unused: 1})
      assert PromptTemplate.variables(template) == [:greeting]
    end
  end

  describe "validate_bindings/2" do
    test "returns the merged bindings when every variable is bound" do
      template = PromptTemplate.from_template("<%= @name %> is <%= @age %>")

      assert {:ok, %{name: "Alice", age: 30}} =
               PromptTemplate.validate_bindings(template, %{name: "Alice", age: 30})
    end

    test "template :inputs defaults count as provided" do
      template = PromptTemplate.from_template("<%= @name %> is <%= @age %>", inputs: %{age: 30})

      assert {:ok, merged} = PromptTemplate.validate_bindings(template, %{name: "Alice"})
      assert merged == %{name: "Alice", age: 30}
    end

    test "lists the variables that are missing" do
      template = PromptTemplate.from_template("<%= @name %> is <%= @age %>")
      assert {:error, [:age]} = PromptTemplate.validate_bindings(template, %{name: "Alice"})
    end

    test "explicit bindings win over :inputs defaults" do
      template = PromptTemplate.from_template("<%= @age %>", inputs: %{age: 1})
      assert {:ok, %{age: 2}} = PromptTemplate.validate_bindings(template, %{age: 2})
    end
  end

  describe "compose/2" do
    test "joins texts, keeps the first role and merges inputs" do
      intro = PromptTemplate.system("You are helpful.", inputs: %{tone: "warm"})
      rules = PromptTemplate.system("Rules: <%= @rules %>", inputs: %{rules: "be brief"})

      combined = PromptTemplate.compose([intro, rules], "\n\n")

      assert combined.role == :system
      assert combined.text == "You are helpful.\n\nRules: <%= @rules %>"
      assert combined.inputs == %{tone: "warm", rules: "be brief"}
      assert PromptTemplate.format(combined, %{}) == "You are helpful.\n\nRules: be brief"
    end

    test "defaults to a newline separator" do
      combined = PromptTemplate.compose([PromptTemplate.user("a"), PromptTemplate.user("b")])
      assert combined.text == "a\nb"
    end

    test "later inputs win on a key collision" do
      a = PromptTemplate.user("<%= @x %>", inputs: %{x: "first"})
      b = PromptTemplate.user("<%= @x %>", inputs: %{x: "second"})
      assert PromptTemplate.compose([a, b]).inputs == %{x: "second"}
    end

    test "the first template's role wins even when the rest differ" do
      combined =
        PromptTemplate.compose([PromptTemplate.assistant("a"), PromptTemplate.system("b")])

      assert combined.role == :assistant
    end

    test "an empty list yields an empty :user template" do
      assert %PromptTemplate{role: :user, text: "", inputs: %{}} = PromptTemplate.compose([])
    end
  end
end
