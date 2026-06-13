defmodule Nous.Memory.Store.ETSConformanceTest do
  @moduledoc """
  Runs the shared `Nous.Memory.Store` conformance battery against the ETS
  backend (always available). The native-dep backends (SQLite/DuckDB/Zvec/
  Muninn) can adopt the same `use Nous.MemoryStoreConformance` with their own
  `init_opts` + a tag, so they run only where the dep is installed.
  """
  use Nous.MemoryStoreConformance, store: Nous.Memory.Store.ETS
end
