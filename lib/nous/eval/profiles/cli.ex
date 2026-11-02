defmodule Nous.Eval.Profiles.CLI do
  @moduledoc false
  # Shared by the `mix nous.profile.*` tasks: argument parsing, the agent
  # factory, stores, refs and exit codes. Nothing here creates an atom from a
  # command-line string: the factory module goes through
  # `Module.safe_concat/1` and its function is looked up among the module's
  # exports.

  alias Nous.{Agent, Profile}
  alias Nous.Errors.ProfileError
  alias Nous.Eval.Profiles

  @stores %{
    "file" => {Nous.Eval.Store.File, :root},
    "sqlite" => {Nous.Eval.Store.SQLite, :path},
    "duckdb" => {Nous.Eval.Store.DuckDB, :path}
  }

  @formats %{"markdown" => :markdown, "console" => :console, "json" => :json}

  @module ~r/\A[A-Z][A-Za-z0-9_]*(\.[A-Z][A-Za-z0-9_]*)*\z/
  @function ~r/\A[a-z_][A-Za-z0-9_]*[?!]?\z/

  @doc false
  # Runs `fun`, mapping `{:error, message}` to exit 2 and `{:fail, message}`
  # to exit 1, both with the message on stderr.
  @spec run(String.t(), (-> :ok | {:error, String.t()} | {:fail, String.t()})) :: :ok
  def run(task, fun) do
    case fun.() do
      :ok ->
        :ok

      {:fail, message} ->
        Mix.shell().error("mix #{task}: " <> message)
        exit({:shutdown, 1})

      {:error, message} ->
        Mix.shell().error("mix #{task}: " <> message)
        exit({:shutdown, 2})
    end
  end

  @doc false
  @spec parse(list(String.t()), keyword(), non_neg_integer() | Range.t()) ::
          {:ok, keyword(), [String.t()]} | {:error, String.t()}
  def parse(argv, switches, positional) do
    case OptionParser.parse(argv, strict: switches) do
      {opts, args, []} ->
        if positional?(length(args), positional),
          do: {:ok, opts, args},
          else: {:error, "expected #{positional_text(positional)}, got #{inspect(args)}"}

      {_opts, _args, [{switch, _} | _]} ->
        {:error, "invalid option #{switch}"}
    end
  end

  defp positional?(n, %Range{} = range), do: n in range
  defp positional?(n, count), do: n == count

  defp positional_text(%Range{first: a, last: b}), do: "#{a} to #{b} arguments"
  defp positional_text(1), do: "1 argument"
  defp positional_text(n), do: "#{n} arguments"

  @doc false
  # `Mod.fun`: a public 0-arity function returning a `%Nous.Agent{}`.
  @spec agent(String.t() | nil) :: {:ok, Agent.t()} | {:error, String.t()}
  def agent(nil), do: {:error, "missing --agent Mod.fun"}

  def agent(spec) do
    with {:ok, module, fun} <- factory(spec),
         {:ok, result} <- call_factory(module, fun, spec) do
      case result do
        %Agent{} = agent ->
          {:ok, agent}

        other ->
          {:error, "--agent #{spec} returned #{inspect(other, limit: 5)}, not a %Nous.Agent{}"}
      end
    end
  end

  # The factory is the operator's code: whatever it raises is reported as an
  # operational error, not a failed check.
  defp call_factory(module, fun, spec) do
    {:ok, apply(module, fun, [])}
  rescue
    e -> {:error, "--agent #{spec} raised: " <> Exception.message(e)}
  end

  defp factory(spec) do
    {module_name, fun_name} =
      case String.split(spec, ".") do
        [_single] -> {"", spec}
        parts -> {parts |> Enum.drop(-1) |> Enum.join("."), List.last(parts)}
      end

    with true <- Regex.match?(@module, module_name) and Regex.match?(@function, fun_name),
         {:ok, module} <- existing_module(module_name),
         {:module, ^module} <- Code.ensure_loaded(module),
         {fun, 0} <-
           Enum.find(module.__info__(:functions), fn {name, arity} ->
             arity == 0 and Atom.to_string(name) == fun_name
           end) do
      {:ok, module, fun}
    else
      false -> {:error, "invalid --agent #{inspect(spec)}: expected Module.function"}
      _ -> {:error, "--agent #{spec}: no public 0-arity function #{spec}/0"}
    end
  end

  defp existing_module(name) do
    {:ok, Module.safe_concat([name])}
  rescue
    ArgumentError -> :error
  end

  @doc false
  @spec open_store(String.t() | nil) :: {:ok, {module(), term()}} | {:error, String.t()}
  def open_store(nil), do: {:error, "missing --store SPEC"}

  def open_store(spec) do
    with [kind, location] when location != "" <- String.split(spec, ":", parts: 2),
         {:ok, {module, key}} <- lookup(@stores, kind, "store") do
      case module.init([{key, location}]) do
        {:ok, state} -> {:ok, {module, state}}
        {:error, reason} -> {:error, "cannot open store #{spec}: #{describe(reason)}"}
      end
    else
      {:error, _} = error ->
        error

      _ ->
        {:error,
         "invalid --store #{inspect(spec)}: expected file:DIR, sqlite:PATH or duckdb:PATH"}
    end
  end

  @doc false
  @spec format(String.t() | nil, String.t()) :: {:ok, atom()} | {:error, String.t()}
  def format(nil, default), do: format(default, default)
  def format(name, _default), do: lookup(@formats, name, "format")

  defp lookup(table, key, name) do
    case Map.fetch(table, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        {:error,
         "unknown #{name} #{inspect(key)}; expected one of #{Enum.join(Enum.sort(Map.keys(table)), ", ")}"}
    end
  end

  @doc false
  # `sha256:<hex>`, `name@label` or `name#version`.
  @spec parse_ref(String.t()) :: {:ok, Nous.Eval.Store.profile_ref()} | :error
  def parse_ref("sha256:" <> _ = id), do: {:ok, {:id, id}}

  def parse_ref(text) do
    cond do
      match?([_, _], String.split(text, "@")) ->
        [name, label] = String.split(text, "@")
        {:ok, {:label, name, label}}

      match?([_, _], String.split(text, "#")) ->
        [name, version] = String.split(text, "#")

        case Integer.parse(version) do
          {n, ""} -> {:ok, {:version, name, n}}
          _ -> :error
        end

      true ->
        :error
    end
  end

  @doc false
  @spec ref_text(Nous.Eval.Store.profile_ref()) :: String.t()
  def ref_text({:id, id}), do: id
  def ref_text({:version, name, n}), do: "#{name}##{n}"
  def ref_text({:label, name, label}), do: "#{name}@#{label}"

  @doc false
  # A profile from a file, or from `store` by ref. `{:error, message}` when
  # it cannot be read (file or store), `{:invalid, message}` when it was read
  # but is not a valid profile.
  @spec load(String.t(), {module(), term()} | nil) ::
          {:ok, Profile.t()} | {:error, String.t()} | {:invalid, String.t()}
  def load(arg, store) do
    cond do
      File.exists?(arg) ->
        case Profile.load(arg) do
          {:ok, profile} -> {:ok, profile}
          {:error, %ProfileError{reason: :file_error} = e} -> {:error, describe(e)}
          {:error, e} -> {:invalid, "#{arg}: #{describe(e)}"}
        end

      match?({:ok, _}, parse_ref(arg)) and is_nil(store) ->
        {:error, "#{arg} is not a file; a store ref needs --store"}

      match?({:ok, _}, parse_ref(arg)) ->
        {:ok, ref} = parse_ref(arg)
        fetch(store, ref)

      true ->
        {:error, "#{arg}: no such file, and not a ref (sha256:<hex>, name@label, name#version)"}
    end
  end

  @doc false
  @spec fetch({module(), term()}, Nous.Eval.Store.profile_ref()) ::
          {:ok, Profile.t()} | {:error, String.t()} | {:invalid, String.t()}
  def fetch({module, state}, ref) do
    case Profiles.fetch(module, state, ref) do
      {:ok, profile} ->
        {:ok, profile}

      {:error, %ProfileError{} = e} ->
        {:invalid, "#{ref_text(ref)}: #{describe(e)}"}

      {:error, {:corrupt_profile, _} = reason} ->
        {:invalid, "#{ref_text(ref)}: #{describe(reason)}"}

      {:error, reason} ->
        {:error, "#{ref_text(ref)}: #{describe(reason)}"}
    end
  end

  @doc false
  # Where `seal` / `rebase` write by default: the input's `.json` sibling.
  @spec default_out(String.t()) :: String.t()
  def default_out(path), do: Path.rootname(path) <> ".json"

  @doc false
  @spec write(String.t(), Profile.t()) :: :ok | {:error, String.t()}
  def write(path, %Profile{} = profile) do
    case File.write(path, Profile.encode(profile) <> "\n") do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot write #{path}: #{:file.format_error(reason)}"}
    end
  end

  @doc false
  @spec describe(term()) :: String.t()
  def describe(%ProfileError{reason: reason, key: key, detail: detail}) do
    [Atom.to_string(reason), key && " #{key}", detail && ": #{detail}"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join()
  end

  def describe(:not_found), do: "not found"
  def describe({:unsupported, module}), do: "#{inspect(module)} does not store profiles"
  def describe({:corrupt_profile, ref}), do: "stored profile does not match #{inspect(ref)}"
  def describe({:name_conflict, name}), do: "already stored under name #{inspect(name)}"
  def describe(message) when is_binary(message), do: message
  def describe(reason), do: inspect(reason)

  @doc false
  @spec short(String.t() | nil) :: String.t()
  def short("sha256:" <> hex), do: "sha256:" <> binary_part(hex, 0, 12)
  def short(other), do: to_string(other)
end
