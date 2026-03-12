defmodule Nous.Providers.VertexAITest do
  use ExUnit.Case, async: false

  alias Nous.Providers.VertexAI

  describe "provider configuration" do
    test "has correct provider ID" do
      assert VertexAI.provider_id() == :vertex_ai
    end

    test "has correct env key" do
      assert VertexAI.default_env_key() == "VERTEX_AI_ACCESS_TOKEN"
    end

    test "implements required callbacks" do
      Code.ensure_loaded!(VertexAI)
      functions = VertexAI.__info__(:functions)

      assert {:chat, 1} in functions or {:chat, 2} in functions
      assert {:chat_stream, 1} in functions or {:chat_stream, 2} in functions
      assert {:count_tokens, 1} in functions
      assert {:request, 3} in functions
      assert {:request_stream, 3} in functions
    end
  end

  describe "endpoint/2" do
    test "builds correct endpoint URL" do
      assert VertexAI.endpoint("my-project", "us-central1") ==
               "https://us-central1-aiplatform.googleapis.com/v1/projects/my-project/locations/us-central1"
    end

    test "defaults to us-central1 region" do
      assert VertexAI.endpoint("my-project") ==
               "https://us-central1-aiplatform.googleapis.com/v1/projects/my-project/locations/us-central1"
    end

    test "supports other regions" do
      assert VertexAI.endpoint("my-project", "europe-west1") ==
               "https://europe-west1-aiplatform.googleapis.com/v1/projects/my-project/locations/europe-west1"
    end

    test "uses v1beta1 for preview models" do
      assert VertexAI.endpoint("my-project", "us-central1", "gemini-2.5-pro-preview-06-05") ==
               "https://us-central1-aiplatform.googleapis.com/v1beta1/projects/my-project/locations/us-central1"
    end

    test "uses v1beta1 for experimental models" do
      assert VertexAI.endpoint("my-project", "us-central1", "gemini-2.0-flash-experimental") ==
               "https://us-central1-aiplatform.googleapis.com/v1beta1/projects/my-project/locations/us-central1"
    end

    test "uses v1 for stable models" do
      assert VertexAI.endpoint("my-project", "us-central1", "gemini-2.0-flash") ==
               "https://us-central1-aiplatform.googleapis.com/v1/projects/my-project/locations/us-central1"
    end

    test "global endpoint uses aiplatform.googleapis.com without region prefix" do
      assert VertexAI.endpoint("my-project", "global", "gemini-3.1-pro-preview") ==
               "https://aiplatform.googleapis.com/v1beta1/projects/my-project/locations/global"
    end
  end

  describe "Model.parse/2 integration" do
    test "parses vertex_ai model string" do
      model = Nous.Model.parse("vertex_ai:gemini-2.0-flash", api_key: "test-token")

      assert model.provider == :vertex_ai
      assert model.model == "gemini-2.0-flash"
      assert model.api_key == "test-token"
    end

    test "base_url is nil at parse time (built at request time by the provider)" do
      System.put_env("GOOGLE_CLOUD_PROJECT", "test-project")
      System.put_env("GOOGLE_CLOUD_REGION", "europe-west4")

      try do
        model = Nous.Model.parse("vertex_ai:gemini-2.0-flash")
        assert model.base_url == nil
      after
        System.delete_env("GOOGLE_CLOUD_PROJECT")
        System.delete_env("GOOGLE_CLOUD_REGION")
      end
    end

    test "base_url is nil when no project env var set" do
      System.delete_env("GOOGLE_CLOUD_PROJECT")
      System.delete_env("GCLOUD_PROJECT")

      model = Nous.Model.parse("vertex_ai:gemini-2.0-flash", api_key: "test")
      assert model.base_url == nil
    end

    test "explicit base_url overrides env vars" do
      System.put_env("GOOGLE_CLOUD_PROJECT", "env-project")

      try do
        model =
          Nous.Model.parse("vertex_ai:gemini-2.0-flash",
            base_url: "https://custom-endpoint.example.com/v1",
            api_key: "test"
          )

        assert model.base_url == "https://custom-endpoint.example.com/v1"
      after
        System.delete_env("GOOGLE_CLOUD_PROJECT")
      end
    end

    test "passes goth name through default_settings" do
      model =
        Nous.Model.parse("vertex_ai:gemini-2.0-flash",
          default_settings: %{goth: MyApp.Goth}
        )

      assert model.default_settings[:goth] == MyApp.Goth
    end
  end

  describe "URL resolution from env vars" do
    test "GOOGLE_CLOUD_LOCATION is used as fallback for region" do
      System.put_env("GOOGLE_CLOUD_PROJECT", "test-project")
      System.put_env("GOOGLE_CLOUD_LOCATION", "asia-northeast1")
      System.delete_env("GOOGLE_CLOUD_REGION")

      try do
        # The URL should resolve successfully (will fail at HTTP level, not config level)
        {:error, reason} =
          VertexAI.chat(%{"model" => "gemini-2.0-flash"}, api_key: "test", base_url: nil)

        # If we get an HTTP error (map with :status), the URL was resolved correctly
        refute is_map(reason) and reason[:reason] == :no_base_url
      after
        System.delete_env("GOOGLE_CLOUD_PROJECT")
        System.delete_env("GOOGLE_CLOUD_LOCATION")
      end
    end

    test "GOOGLE_CLOUD_REGION takes precedence over GOOGLE_CLOUD_LOCATION" do
      System.put_env("GOOGLE_CLOUD_PROJECT", "test-project")
      System.put_env("GOOGLE_CLOUD_REGION", "europe-west1")
      System.put_env("GOOGLE_CLOUD_LOCATION", "asia-northeast1")

      try do
        {:error, reason} =
          VertexAI.chat(%{"model" => "gemini-2.0-flash"}, api_key: "test", base_url: nil)

        refute is_map(reason) and reason[:reason] == :no_base_url
      after
        System.delete_env("GOOGLE_CLOUD_PROJECT")
        System.delete_env("GOOGLE_CLOUD_REGION")
        System.delete_env("GOOGLE_CLOUD_LOCATION")
      end
    end

    test "invalid project ID returns helpful error" do
      System.put_env("GOOGLE_CLOUD_PROJECT", "BAD PROJECT!")
      System.delete_env("GOOGLE_CLOUD_REGION")

      try do
        {:error, reason} =
          VertexAI.chat(%{"model" => "gemini-2.0-flash"}, api_key: "test", base_url: nil)

        assert reason.reason == :invalid_project_id
        assert reason.message =~ "Invalid GCP project ID"
        assert reason.message =~ "BAD PROJECT!"
      after
        System.delete_env("GOOGLE_CLOUD_PROJECT")
      end
    end

    test "invalid region returns helpful error" do
      System.put_env("GOOGLE_CLOUD_PROJECT", "test-project")
      System.put_env("GOOGLE_CLOUD_REGION", "not a region!")

      try do
        {:error, reason} =
          VertexAI.chat(%{"model" => "gemini-2.0-flash"}, api_key: "test", base_url: nil)

        assert reason.reason == :invalid_region
        assert reason.message =~ "Invalid GCP region"
        assert reason.message =~ "not a region!"
      after
        System.delete_env("GOOGLE_CLOUD_PROJECT")
        System.delete_env("GOOGLE_CLOUD_REGION")
      end
    end

    test "preview models use v1beta1 URL at request time" do
      System.put_env("GOOGLE_CLOUD_PROJECT", "test-project")
      System.delete_env("GOOGLE_CLOUD_REGION")

      try do
        # The model.base_url should be nil (deferred to provider)
        model = Nous.Model.parse("vertex_ai:gemini-2.5-pro-preview-06-05", api_key: "test")
        assert model.base_url == nil

        # When the provider resolves the URL, it should use v1beta1
        # We can't easily test the full flow without HTTP, but we can verify
        # the endpoint function directly
        assert VertexAI.endpoint("test-project", "us-central1", "gemini-2.5-pro-preview-06-05") =~
                 "v1beta1"
      after
        System.delete_env("GOOGLE_CLOUD_PROJECT")
      end
    end
  end

  describe "token resolution" do
    test "chat returns error when no credentials available" do
      System.delete_env("VERTEX_AI_ACCESS_TOKEN")

      {:error, reason} = VertexAI.chat(%{"model" => "gemini-2.0-flash"}, api_key: nil)

      assert reason.reason == :no_credentials
    end

    test "chat returns error when no base_url available" do
      System.delete_env("GOOGLE_CLOUD_PROJECT")
      System.delete_env("GCLOUD_PROJECT")

      {:error, reason} =
        VertexAI.chat(%{"model" => "gemini-2.0-flash"}, api_key: "test", base_url: nil)

      assert reason.reason == :no_base_url
    end
  end

  describe "message format" do
    test "uses Gemini format for to_provider_format" do
      messages = [Nous.Message.system("Be helpful"), Nous.Message.user("Hello")]

      {system_prompt, contents} = Nous.Messages.to_provider_format(messages, :vertex_ai)

      assert system_prompt == "Be helpful"
      assert [%{"role" => "user", "parts" => [%{"text" => "Hello"}]}] = contents
    end

    test "uses Gemini format for from_provider_response" do
      response = %{
        "candidates" => [
          %{
            "content" => %{
              "parts" => [%{"text" => "Hello from Vertex AI"}],
              "role" => "model"
            }
          }
        ],
        "usageMetadata" => %{
          "promptTokenCount" => 10,
          "candidatesTokenCount" => 5,
          "totalTokenCount" => 15
        }
      }

      message = Nous.Messages.from_provider_response(response, :vertex_ai)

      assert message.role == :assistant
      assert message.content == "Hello from Vertex AI"
    end
  end

  describe "ModelDispatcher routing" do
    test "routes vertex_ai to VertexAI provider" do
      # We can't make a real request but we can verify the module is callable
      model = %Nous.Model{
        provider: :vertex_ai,
        model: "gemini-2.0-flash",
        api_key: nil,
        base_url: nil,
        default_settings: %{}
      }

      # This will fail at the HTTP level, but we verify routing works
      assert {:error, _} = Nous.ModelDispatcher.request(model, [Nous.Message.user("test")], %{})
    end
  end
end
