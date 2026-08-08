defmodule Nous.Memory.Store.ETSConformanceTest do
  @moduledoc """
  Runs the shared `Nous.Memory.Store` conformance battery against the ETS
  backend (always available). The native-dep backends (SQLite, DuckDB) can adopt
  the same `use Nous.Memory.Store.Conformance` with their own `init_opts` plus a
  tag, so they run only where the dep is installed — and so can a backend
  implemented outside Nous, which is why the kit ships in `lib/`.
  """
  use Nous.Memory.Store.Conformance, store: Nous.Memory.Store.ETS
end
