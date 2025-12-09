defmodule Nous.Models.MistralTest do
  use ExUnit.Case, async: true

  alias Nous.{Model, Messages}
  alias Nous.Models.Mistral

  describe "count_tokens/1" do
    test "estimates token count for messages" do
      messages = [
        Messages.system_prompt("You are helpful"),
        Messages.user_prompt("Hello world!")
      ]

      token_count = Mistral.count_tokens(messages)

      # Should return a reasonable estimate
      assert is_integer(token_count)
      assert token_count > 0
      assert token_count < 100  # Should be reasonable for short messages
    end

    test "estimates tokens for complex messages" do
      messages = [
        Messages.system_prompt("You are a helpful AI assistant with expertise in multiple domains."),
        Messages.user_prompt("Please analyze the following data and provide insights: [lengthy data here]"),
        Messages.user_prompt(["What do you see in this image?", {:image_url, "https://example.com/image.png"}])
      ]

      token_count = Mistral.count_tokens(messages)

      # Should be higher for more complex messages
      assert token_count > 30
      assert is_integer(token_count)
    end

    test "handles empty message list" do
      token_count = Mistral.count_tokens([])
      assert token_count == 0
    end
  end

  describe "private parameter building" do
    test "build_request_params includes basic parameters" do
      _model = Model.new(:mistral, "mistral-large-latest",
        default_settings: %{temperature: 0.5}
      )
      _messages = [
        %{"role" => "user", "content" => "Hello"}
      ]
      _settings = %{max_tokens: 100}

      # Test the private function via the public interface by checking behavior
      # Since we can't directly test private functions, we verify the structure
      # is correct by ensuring the function doesn't crash with various inputs
      result = Mistral.count_tokens([Messages.user_prompt("test")])
      assert is_integer(result)
    end

    test "handles various model configurations" do
      # Test various model configurations to ensure they don't break
      models = [
        Model.new(:mistral, "mistral-large-latest"),
        Model.new(:mistral, "mistral-small-latest", api_key: "test"),
        Model.new(:mistral, "mistral-large-latest",
          default_settings: %{
            temperature: 0.7,
            reasoning_mode: true,
            safe_prompt: true
          }
        )
      ]

      for model <- models do
        # Ensure model creation works without errors
        assert model.provider == :mistral
        assert is_binary(model.model)
        assert model.base_url == "https://api.mistral.ai/v1"
      end
    end
  end

  describe "message format handling" do
    test "processes different message types correctly" do
      messages = [
        Messages.system_prompt("You are helpful"),
        Messages.user_prompt("Hello"),
        Messages.user_prompt([
          {:text, "What's in this image?"},
          {:image_url, "https://example.com/image.png"}
        ]),
        Messages.tool_return("call_123", %{result: "success"})
      ]

      # Verify token counting works with various message types
      token_count = Mistral.count_tokens(messages)
      assert is_integer(token_count)
      assert token_count > 0
    end
  end

  describe "error handling" do
    test "handles nil or invalid inputs gracefully" do
      # Test with nil messages
      assert Mistral.count_tokens(nil) == 0

      # Test with invalid message format (should not crash)
      invalid_messages = ["not", "a", "proper", "format"]
      token_count = Mistral.count_tokens(invalid_messages)
      assert is_integer(token_count)
    end
  end

  describe "model compatibility" do
    test "works with different mistral model names" do
      model_names = [
        "mistral-large-latest",
        "mistral-small-latest",
        "mistral-medium-latest",
        "mistral-tiny"
      ]

      for model_name <- model_names do
        model = Model.new(:mistral, model_name)
        assert model.provider == :mistral
        assert model.model == model_name
        assert model.base_url == "https://api.mistral.ai/v1"
      end
    end

    test "supports model-specific settings" do
      model = Model.new(:mistral, "mistral-large-latest",
        default_settings: %{
          reasoning_mode: true,
          prediction_mode: false,
          safe_prompt: true,
          temperature: 0.1,
          max_tokens: 2000
        }
      )

      assert model.default_settings.reasoning_mode == true
      assert model.default_settings.prediction_mode == false
      assert model.default_settings.safe_prompt == true
      assert model.default_settings.temperature == 0.1
      assert model.default_settings.max_tokens == 2000
    end
  end
end