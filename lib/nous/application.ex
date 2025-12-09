defmodule Nous.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Finch HTTP client pool for openai_ex
      {Finch,
       name: Nous.Finch,
       pools: %{
         # OpenAI
         "https://api.openai.com" => [size: 10],
         # Groq
         "https://api.groq.com" => [size: 10],
         # OpenRouter
         "https://openrouter.ai" => [size: 10],
         # Together AI
         "https://api.together.xyz" => [size: 10],
         # Local Ollama
         "http://localhost:11434" => [size: 5],
         # Local LM Studio
         "http://localhost:1234" => [size: 5]
       }}
    ]

    opts = [strategy: :one_for_one, name: Nous.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
