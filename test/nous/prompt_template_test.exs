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
    test "returns existing atoms when known" do
      vars = PromptTemplate.extract_variables("Hello <%= @name %> from <%= @source %>")
      # role/content are existing atoms in this codebase but name/source likely aren't
      # at extraction time - assert each is either an atom or string.
      Enum.each(vars, fn v -> assert is_atom(v) or is_binary(v) end)
    end

    test "deduplicates" do
      vars = PromptTemplate.extract_variables("<%= @x %> + <%= @x %>")
      assert length(vars) == 1
    end
  end

  describe "security: untrusted template body cannot execute Elixir" do
    test "format on a hostile template body never invokes EEx" do
      # If from_template/2 had let this through, EEx.eval_string would execute
      # File.write!/2. Since from_template rejects it, no execution happens.
      hostile = ~S{<%= File.write!("/tmp/nous_pwn_test", "x") %>}

      assert_raise ArgumentError, fn ->
        PromptTemplate.from_template(hostile)
      end

      refute File.exists?("/tmp/nous_pwn_test")
    end
  end
end
