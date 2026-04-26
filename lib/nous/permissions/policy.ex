defmodule Nous.Permissions.Policy do
  @moduledoc """
  Permission policy controlling tool access.

  Defines which tools are denied, which require approval,
  and the overall permission mode.

  ## Modes

    * `:default` — read/search tools are open, write/execute tools require approval
    * `:permissive` — all tools are open, none require approval
    * `:strict` — all tools require approval; at the filter layer, ONLY tools
      in `:allow_names` / `:allow_prefixes` are exposed (deny-by-default).

  ## Examples

      # Custom policy that blocks bash and requires approval for write tools
      %Nous.Permissions.Policy{
        deny_names: MapSet.new(["bash"]),
        approval_required: MapSet.new(["file_write", "file_edit"]),
        mode: :default
      }

      # Strict + explicit allowlist
      %Nous.Permissions.Policy{
        mode: :strict,
        allow_names: MapSet.new(["file_read", "search_web"])
      }

  """

  defstruct deny_names: MapSet.new(),
            deny_prefixes: [],
            allow_names: MapSet.new(),
            allow_prefixes: [],
            approval_required: MapSet.new(),
            mode: :default

  @type mode :: :default | :permissive | :strict

  @type t :: %__MODULE__{
          deny_names: MapSet.t(),
          deny_prefixes: [String.t()],
          allow_names: MapSet.t(),
          allow_prefixes: [String.t()],
          approval_required: MapSet.t(),
          mode: mode()
        }
end
