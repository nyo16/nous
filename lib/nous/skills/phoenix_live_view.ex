defmodule Nous.Skills.PhoenixLiveView do
  @moduledoc """
  Built-in skill — Phoenix LiveView lifecycle, components and anti-patterns.

  Injects a system-prompt section on the double `mount/3` and the
  `connected?/1` side-effect guard, never passing the socket into business
  logic, LiveComponent isolation via `@myself`, the `preload/1` batch callback,
  map lookups instead of `Enum.find/3`, the
  `handle_event`/`handle_info`/`handle_params` split, and the usual traps —
  fat LiveView modules, unguarded queries in `mount/3`, and `raw/1` XSS.

  Activates on prompts containing "liveview", "live_view", "live view", "mount",
  "handle_event", "handle_info", "live_component" or "phoenix component".
  Group `:coding`; tags `:elixir`, `:phoenix`, `:liveview`, `:web`.
  """

  use Nous.Skill,
    keywords: [
      "liveview",
      "live_view",
      "live view",
      "mount",
      "handle_event",
      "handle_info",
      "live_component",
      "phoenix component"
    ],
    tags: [:elixir, :phoenix, :liveview, :web],
    group: :coding

  @impl true
  def name, do: "phoenix_liveview"

  @impl true
  def description, do: "Phoenix LiveView patterns, lifecycle, components, and anti-patterns"

  @impl true
  def instructions(_agent, _ctx) do
    """
    You are a Phoenix LiveView specialist. Follow these critical patterns:

    1. **Mount is called twice**: Once for static render, again on WebSocket connect. Gate side-effects:
       ```elixir
       def mount(_params, _session, socket) do
         if connected?(socket) do
           Phoenix.PubSub.subscribe(MyApp.PubSub, "topic")
         end
         {:ok, assign(socket, data: load_data())}
       end
       ```

    2. **Never pass socket to business logic**: Extract specific assigns, return data for assignment:
       ```elixir
       # Wrong: my_function(socket)
       # Right: result = my_function(socket.assigns.user_id)
       #        {:noreply, assign(socket, result: result)}
       ```

    3. **Use LiveComponents for isolation**: Components own their own state and events via `@myself`:
       ```elixir
       <.live_component module={SearchComponent} id="search" />
       ```
       Components communicate upward with `send(self(), {:event, data})`.

    4. **Preload in list components**: Use `preload/1` callback to batch-load data for all component instances.

    5. **Convert lists to maps for O(1) lookups**: `Map.new(users, &{&1.id, &1})` instead of `Enum.find/3`.

    6. **Handle events properly**: Use `handle_event/3` for user interactions, `handle_info/2` for process messages, `handle_params/3` for URL changes.

    7. **Avoid**: Fat LiveView modules (extract to components), querying in mount without `connected?/1` guard, using `raw/1` with user input (XSS risk).
    """
  end
end
