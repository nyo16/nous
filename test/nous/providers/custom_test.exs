defmodule Nous.Providers.CustomTest do
  # async: false — manipulates the CUSTOM_BASE_URL env var.
  use ExUnit.Case, async: false

  alias Nous.Providers.Custom

  setup do
    prev = System.get_env("CUSTOM_BASE_URL")
    System.delete_env("CUSTOM_BASE_URL")
    on_exit(fn -> restore("CUSTOM_BASE_URL", prev) end)

    bypass = Bypass.open()
    %{bypass: bypass, base: "http://localhost:#{bypass.port}/v1"}
  end

  defp restore(k, nil), do: System.delete_env(k)
  defp restore(k, v), do: System.put_env(k, v)

  describe "macro-injected metadata" do
    test "exposes provider_id and default_env_key" do
      assert Custom.provider_id() == :custom
      assert Custom.default_env_key() == "CUSTOM_API_KEY"
    end
  end

  describe "chat/2 missing base_url" do
    test "returns {:error, {:invalid_config, _}} when no base_url is configured" do
      assert {:error, {:invalid_config, msg}} =
               Custom.chat(%{"model" => "m", "messages" => []})

      assert msg =~ "requires a base_url"
    end

    test "chat_stream returns {:error, {:invalid_config, _}} when no base_url is configured" do
      assert {:error, {:invalid_config, msg}} =
               Custom.chat_stream(%{"model" => "m", "messages" => []})

      assert msg =~ "requires a base_url"
    end
  end

  describe "chat/2 SSRF validation" do
    test "rejects private hosts by default" do
      assert {:error, {:invalid_config, msg}} =
               Custom.chat(%{"model" => "m", "messages" => []},
                 base_url: "http://127.0.0.1:9/v1"
               )

      assert msg =~ "SSRF validation"
    end

    test "allows private hosts when allow_private_hosts: true", %{bypass: bypass, base: base} do
      Bypass.expect_once(bypass, "POST", "/v1/chat/completions", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, ~s({"id": "x"}))
      end)

      assert {:ok, %{"id" => "x"}} =
               Custom.chat(%{"model" => "m", "messages" => []},
                 base_url: base,
                 allow_private_hosts: true
               )
    end

    test "rejects non-http schemes" do
      assert {:error, {:invalid_config, _}} =
               Custom.chat(%{"model" => "m", "messages" => []},
                 base_url: "file:///etc/passwd"
               )
    end
  end
end
