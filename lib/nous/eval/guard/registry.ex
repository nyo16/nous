defmodule Nous.Eval.Guard.Registry do
  @moduledoc """
  The compiled-in registry of guard datasets `mix nous.eval.datasets.fetch`
  may download: per source, the files pinned to an upstream commit with
  their sha256, the licence and its status, and the adapter that turns an
  upstream row into a `nous.guard_case/1` case.

  | Status | Meaning |
  |---|---|
  | `:allowed` | permissive licence (MIT, Apache-2.0, CC-BY-4.0, ...) |
  | `:terms` | redistributable but use-restricted: fetched only with `--accept-terms <id>`, recorded in the manifest, never committed |
  | `:denied` | non-commercial, copyleft, no licence or private: never fetched |

  Licences were read from the HF Hub API (`cardData.license`) and the GitHub
  licence API at the pinned revisions (2026-11-01). Checksums are of the
  exact files at those revisions; a download that does not match is
  refused before it is parsed.

  The `nous_builtin` source is Nous's own guard dataset
  (`test/fixtures/guard/*.jsonl` in the repository) at the GitHub tag of
  this release, `v#{Mix.Project.config()[:version]}`: the Hex package does
  not ship it.
  """

  alias Nous.Eval.Guard.Case

  @version Mix.Project.config()[:version]

  @type file :: %{
          name: String.t(),
          url: String.t(),
          sha256: String.t(),
          format: :csv | :json | :jsonl | :parquet | :guard_jsonl,
          split: String.t() | nil
        }

  @type source :: %{
          id: String.t(),
          title: String.t(),
          homepage: String.t(),
          license: String.t(),
          license_url: String.t() | nil,
          status: :allowed | :terms | :denied,
          reason: String.t() | nil,
          revision: String.t() | nil,
          gated: boolean(),
          public: boolean(),
          surfaces: [Case.surface()],
          attribution: String.t(),
          files: [file()],
          adapter: (file(), map(), non_neg_integer() -> {:ok, map()} | :skip) | nil
        }

  @deepset_rev "4f61ecb038e9c3fb77e21034b22511b523772cdd"
  @jackhhao_rev "2f2ceeb39658696fd3f462403562b6eea5306287"
  @gandalf_rev "04737b65e90a6794ec227012e4a255a7def6344b"
  @xstest_rev "d7bb5bd738c1fcbc36edd83d5e7d1b71a3e2d84d"
  @injecagent_rev "f19c9f2c79a41046eb13c03c51a24c567a8ffa07"
  @jbb_rev "886acc352a31533ffbcf4ef22c744658688086fc"
  @agentharm_rev "e23b3fe60a0da9037314b88e5ee3a0c054970dad"

  # The canonical JSONL files of `test/fixtures/guard` at this release
  # (`Nous.Eval.Guard.Hygiene.canonical_jsonl/1`); a test keeps them in step
  # with the repository.
  @builtin_files [
    {"model_output.jsonl", "7fbb54e641df7f4057070fb6c58fd8a2d701a04ce94728f9ac65f5da6bf77999"},
    {"tool_call.jsonl", "cec27f66e9f6f75161577c07b8170152ff9e6ca8a222798d173cc89068eb7230"},
    {"tool_result.jsonl", "7e51ce19ffffd741fdc2d8ffa36bd66eb1ef31cb6dec27649b780ccbf54d2626"},
    {"user_input.jsonl", "21d32f920a04a0136a2cb214623a7e5e46871916237420504f52bc1388d91cf7"}
  ]

  @doc "Every registered source."
  @spec sources() :: [source()]
  def sources do
    [
      builtin(),
      %{
        id: "deepset/prompt-injections",
        title: "deepset prompt-injections (test split)",
        homepage: "https://huggingface.co/datasets/deepset/prompt-injections",
        license: "Apache-2.0",
        license_url: "https://www.apache.org/licenses/LICENSE-2.0",
        status: :allowed,
        reason: nil,
        revision: @deepset_rev,
        gated: false,
        public: true,
        surfaces: [:user_input],
        attribution: "deepset GmbH, deepset/prompt-injections (Apache-2.0)",
        files: [
          hf(
            "deepset/prompt-injections",
            @deepset_rev,
            "data/test-00000-of-00001-701d16158af87368.parquet",
            "39ac797cabc157eeed58435a08593b2952bb6cb16fc394a2d383f447cc7b246e",
            :parquet,
            "test"
          )
        ],
        adapter: &__MODULE__.Adapters.deepset/3
      },
      %{
        id: "jackhhao/jailbreak-classification",
        title: "jackhhao jailbreak-classification (test split)",
        homepage: "https://huggingface.co/datasets/jackhhao/jailbreak-classification",
        license: "Apache-2.0",
        license_url: "https://www.apache.org/licenses/LICENSE-2.0",
        status: :allowed,
        reason: nil,
        revision: @jackhhao_rev,
        gated: false,
        public: true,
        surfaces: [:user_input],
        attribution:
          "jackhhao/jailbreak-classification (Apache-2.0); jailbreaks from verazuo/jailbreak_llms (MIT), " <>
            "benign prompts from OpenOrca (MIT) and GPTeacher (MIT)",
        files: [
          hf(
            "jackhhao/jailbreak-classification",
            @jackhhao_rev,
            "balanced/jailbreak_dataset_test_balanced.csv",
            "809ef0d7c82fa05c31e818e9c3ff68f769632ac6d11cc3b43254cada577869a9",
            :csv,
            "test"
          )
        ],
        adapter: &__MODULE__.Adapters.jackhhao/3
      },
      %{
        id: "Lakera/gandalf_ignore_instructions",
        title: "Lakera gandalf_ignore_instructions (validation + test)",
        homepage: "https://huggingface.co/datasets/Lakera/gandalf_ignore_instructions",
        license: "MIT",
        license_url: "https://opensource.org/license/mit",
        status: :allowed,
        reason: nil,
        revision: @gandalf_rev,
        gated: false,
        public: true,
        surfaces: [:user_input],
        attribution: "Lakera AI, gandalf_ignore_instructions (MIT)",
        files: [
          hf(
            "Lakera/gandalf_ignore_instructions",
            @gandalf_rev,
            "data/validation-00000-of-00001-94481a2a09ff2fff.parquet",
            "f51ab3e3407a368845b0f57932cc745c09280429416d7507bd178a16326a79f6",
            :parquet,
            "validation"
          ),
          hf(
            "Lakera/gandalf_ignore_instructions",
            @gandalf_rev,
            "data/test-00000-of-00001-bc92128b9288a6d1.parquet",
            "56b646d133335ebc535266bd55dbe1b5bee7caa4b95bf49d040684b9b5dd9972",
            :parquet,
            "test"
          )
        ],
        adapter: &__MODULE__.Adapters.gandalf/3
      },
      %{
        id: "paul-rottger/xstest",
        title: "XSTest v2 prompts",
        homepage: "https://github.com/paul-rottger/xstest",
        license: "CC-BY-4.0",
        license_url: "https://creativecommons.org/licenses/by/4.0/",
        status: :allowed,
        reason: nil,
        revision: @xstest_rev,
        gated: false,
        public: true,
        surfaces: [:user_input],
        attribution:
          "Röttger et al., XSTest: A Test Suite for Identifying Exaggerated Safety Behaviours in Large " <>
            "Language Models (CC-BY-4.0); modified: sampled and reformatted",
        files: [
          gh(
            "paul-rottger/xstest",
            @xstest_rev,
            "xstest_prompts.csv",
            "11783fb294ed017473ee53c207d71f2161c7672c8d0b037501e78387f801cb5a",
            :csv,
            nil
          )
        ],
        adapter: &__MODULE__.Adapters.xstest/3
      },
      %{
        id: "uiuc-kang-lab/InjecAgent",
        title: "InjecAgent base test cases (direct harm + data stealing)",
        homepage: "https://github.com/uiuc-kang-lab/InjecAgent",
        license: "MIT",
        license_url: "https://opensource.org/license/mit",
        status: :allowed,
        reason: nil,
        revision: @injecagent_rev,
        gated: false,
        public: true,
        surfaces: [:tool_result],
        attribution: "Zhan et al., InjecAgent (MIT)",
        files: [
          gh(
            "uiuc-kang-lab/InjecAgent",
            @injecagent_rev,
            "data/test_cases_dh_base.json",
            "0a8186468d21389af432e8c7b399ae42264d1b93a07b65c7a489468508604305",
            :json,
            "dh_base"
          ),
          gh(
            "uiuc-kang-lab/InjecAgent",
            @injecagent_rev,
            "data/test_cases_ds_base.json",
            "4daab35c62a3845e8b9400f4dca58b9c9f37e57cd33b2337552557fbb26282e9",
            :json,
            "ds_base"
          )
        ],
        adapter: &__MODULE__.Adapters.injecagent/3
      },
      %{
        id: "JailbreakBench/JBB-Behaviors",
        title: "JailbreakBench JBB-Behaviors (harmful + benign behaviours)",
        homepage: "https://huggingface.co/datasets/JailbreakBench/JBB-Behaviors",
        license: "MIT",
        license_url: "https://opensource.org/license/mit",
        status: :allowed,
        reason: nil,
        revision: @jbb_rev,
        gated: false,
        public: true,
        surfaces: [:user_input],
        attribution:
          "JailbreakBench, JBB-Behaviors (MIT); sources AdvBench, HarmBench, TDC (MIT)",
        files: [
          hf(
            "JailbreakBench/JBB-Behaviors",
            @jbb_rev,
            "data/harmful-behaviors.csv",
            "4a8ec6832056b631eb092dccc60d37a61c3d441268268888b3d006288afeffa1",
            :csv,
            "harmful"
          ),
          hf(
            "JailbreakBench/JBB-Behaviors",
            @jbb_rev,
            "data/benign-behaviors.csv",
            "3cda234d21a991fa309bbfea4b6d9dae31ccdf8e9d452424b6a983e4fdc33468",
            :csv,
            "benign"
          )
        ],
        adapter: &__MODULE__.Adapters.jbb/3
      },
      %{
        id: "ai-safety-institute/AgentHarm",
        title: "AgentHarm public test behaviours (harmful + benign)",
        homepage: "https://huggingface.co/datasets/ai-safety-institute/AgentHarm",
        license: "LicenseRef-MIT-use-restricted",
        license_url: "https://huggingface.co/datasets/ai-safety-institute/AgentHarm",
        status: :terms,
        reason:
          "MIT with an added clause: the data may not be used for purposes besides improving the safety " <>
            "and security of AI systems; the clause travels with every copy",
        revision: @agentharm_rev,
        gated: false,
        public: true,
        surfaces: [:user_input],
        attribution:
          "UK AI Safety Institute and Gray Swan AI, AgentHarm (MIT with use restriction)",
        files: [
          hf(
            "ai-safety-institute/AgentHarm",
            @agentharm_rev,
            "benchmark/harmful_behaviors_test_public.json",
            "fc3e4abbcd812022b85150b0e6f81c0bdbdfabb486e5b82ec46f1ba135f3ba08",
            :json,
            "harmful"
          ),
          hf(
            "ai-safety-institute/AgentHarm",
            @agentharm_rev,
            "benchmark/benign_behaviors_test_public.json",
            "65b4ebd4d8d2e7c9a79db4e11bc642f1800e642be0626ba0a990c763a325957a",
            :json,
            "benign"
          )
        ],
        adapter: &__MODULE__.Adapters.agentharm/3
      },
      %{
        id: "lmsys/toxic-chat",
        title: "ToxicChat",
        homepage: "https://huggingface.co/datasets/lmsys/toxic-chat",
        license: "CC-BY-NC-4.0",
        license_url: "https://creativecommons.org/licenses/by-nc/4.0/",
        status: :denied,
        reason:
          "non-commercial licence (CC-BY-NC-4.0): load it yourself as a local dataset if your use allows",
        revision: nil,
        gated: false,
        public: true,
        surfaces: [:user_input],
        attribution: "",
        files: [],
        adapter: nil
      }
    ]
  end

  defp builtin do
    %{
      id: "nous_builtin",
      title: "Nous built-in guard dataset (v#{@version})",
      homepage: "https://github.com/nyo16/nous/tree/v#{@version}/test/fixtures/guard",
      license: "see NOTICE (MIT, Apache-2.0, CC-BY-4.0 per case)",
      license_url: "https://github.com/nyo16/nous/blob/v#{@version}/test/fixtures/guard/NOTICE",
      status: :allowed,
      reason: nil,
      revision: "v" <> @version,
      gated: false,
      public: true,
      surfaces: [:user_input, :tool_call, :tool_result, :model_output],
      attribution: "Nous contributors; third-party cases carry their own provenance",
      files:
        for {name, sha} <- @builtin_files do
          %{
            name: name,
            url:
              "https://raw.githubusercontent.com/nyo16/nous/v#{@version}/test/fixtures/guard/#{name}",
            sha256: sha,
            format: :guard_jsonl,
            split: nil
          }
        end,
      adapter: nil
    }
  end

  @doc false
  # The `{file, sha256}` pairs of the built-in dataset this release pins.
  @spec builtin_files() :: [{String.t(), String.t()}]
  def builtin_files, do: @builtin_files

  defp hf(repo, rev, path, sha, format, split) do
    %{
      name: Path.basename(path),
      url: "https://huggingface.co/datasets/#{repo}/resolve/#{rev}/#{path}",
      sha256: sha,
      format: format,
      split: split
    }
  end

  defp gh(repo, rev, path, sha, format, split) do
    %{
      name: Path.basename(path),
      url: "https://raw.githubusercontent.com/#{repo}/#{rev}/#{path}",
      sha256: sha,
      format: format,
      split: split
    }
  end

  @doc """
  The source registered as `id` (`"name"` or `"name@revision"`; only the
  pinned revision can be fetched, because only its checksums are known), in
  `sources` (default `sources/0`).
  """
  @spec fetch(String.t(), [source()]) :: {:ok, source()} | {:error, String.t()}
  def fetch(spec, sources \\ sources()) when is_binary(spec) do
    {id, rev} =
      case String.split(spec, "@", parts: 2) do
        [id, rev] -> {id, rev}
        [id] -> {id, nil}
      end

    case Enum.find(sources, &(&1.id == id)) do
      nil ->
        {:error, "unknown source #{inspect(id)}; known: #{Enum.map_join(sources, ", ", & &1.id)}"}

      %{revision: pinned} = source when rev in [nil, pinned] ->
        {:ok, source}

      %{revision: pinned} ->
        {:error,
         "#{id}@#{rev}: only the pinned revision #{pinned} can be fetched (its sha256s are compiled into this release)"}
    end
  end

  defmodule Adapters do
    @moduledoc false
    # Row -> `nous.guard_case/1` map adapters, one per registry source. Label
    # mappings are literal tables; nothing from a row becomes an atom.

    @deepset_labels %{1 => {"block", "prompt_injection"}, 0 => {"allow", "benign"}}
    @jackhhao_labels %{"jailbreak" => {"block", "jailbreak"}, "benign" => {"allow", "benign"}}
    @xstest_labels %{"safe" => "allow", "unsafe" => "block"}

    def deepset(file, %{"text" => text, "label" => label}, row) when is_binary(text) do
      with {:ok, {verdict, category}} <- Map.fetch(@deepset_labels, label) do
        {:ok,
         base("deepset-#{row}", "user_input", verdict, %{"text" => text},
           category: category,
           provenance: %{
             "source" => "deepset/prompt-injections (test split)",
             "source_url" => "https://huggingface.co/datasets/deepset/prompt-injections",
             "license" => "Apache-2.0",
             "license_note" => "card lists apache-2.0 and a nested cc-by-4.0",
             "source_revision" => "4f61ecb038e9c3fb77e21034b22511b523772cdd",
             "source_split" => file.split,
             "source_row" => row,
             "upstream_label" => to_string(label)
           }
         )}
      else
        _ -> :skip
      end
    end

    def deepset(_file, _row, _index), do: :skip

    def jackhhao(file, %{"prompt" => text, "type" => type}, row) do
      case Map.fetch(@jackhhao_labels, type) do
        {:ok, {verdict, category}} ->
          {:ok,
           base("jackhhao-test-#{row}", "user_input", verdict, %{"text" => text},
             category: category,
             provenance: %{
               "source" => "jackhhao/jailbreak-classification (test split)",
               "source_url" =>
                 "https://huggingface.co/datasets/jackhhao/jailbreak-classification",
               "license" => "Apache-2.0",
               "attribution" =>
                 "jailbreaks: verazuo/jailbreak_llms (MIT); benign: OpenOrca (MIT), GPTeacher (MIT)",
               "source_revision" => "2f2ceeb39658696fd3f462403562b6eea5306287",
               "source_split" => file.split,
               "source_row" => row,
               "upstream_label" => type
             }
           )}

        :error ->
          :skip
      end
    end

    def jackhhao(_file, _row, _index), do: :skip

    def gandalf(file, %{"text" => text}, row) when is_binary(text) do
      {:ok,
       base("gandalf-#{file.split}-#{row}", "user_input", "block", %{"text" => text},
         category: "prompt_injection",
         provenance: %{
           "source" => "Lakera/gandalf_ignore_instructions (#{file.split} split)",
           "source_url" => "https://huggingface.co/datasets/Lakera/gandalf_ignore_instructions",
           "license" => "MIT",
           "source_revision" => "04737b65e90a6794ec227012e4a255a7def6344b",
           "source_split" => file.split,
           "source_row" => row,
           "upstream_label" => "ignore_instructions"
         }
       )}
    end

    def gandalf(_file, _row, _index), do: :skip

    def xstest(_file, %{"id" => id, "prompt" => text, "label" => label} = r, _row) do
      case Map.fetch(@xstest_labels, label) do
        {:ok, verdict} ->
          {:ok,
           base("xstest-#{id}", "user_input", verdict, %{"text" => text},
             category: r["type"],
             tags: if(verdict == "allow", do: ["hard_negative"], else: []),
             provenance: %{
               "source" => "paul-rottger/xstest (xstest_prompts.csv)",
               "source_url" => "https://github.com/paul-rottger/xstest",
               "license" => "CC-BY-4.0",
               "license_url" => "https://creativecommons.org/licenses/by/4.0/",
               "attribution" =>
                 "Röttger et al., XSTest (CC-BY-4.0); modified: sampled and reformatted",
               "source_revision" => "d7bb5bd738c1fcbc36edd83d5e7d1b71a3e2d84d",
               "source_row" => id,
               "upstream_label" => label
             }
           )}

        :error ->
          :skip
      end
    end

    def xstest(_file, _row, _index), do: :skip

    def injecagent(file, %{"Tool Response" => result, "User Tool" => tool} = r, row)
        when is_binary(result) and is_binary(tool) do
      category =
        if file.split == "ds_base", do: "data_exfiltration_request", else: "embedded_instructions"

      attack = r["Attacker Instruction"] || ""

      {:ok,
       base(
         "injecagent-#{file.split}-#{row}",
         "tool_result",
         "block",
         %{
           "tool" => %{"name" => tool},
           "arguments" => python_dict(r["Tool Parameters"]),
           "result" => result,
           "task" => r["User Instruction"]
         },
         category: category,
         provenance: %{
           "source" => "uiuc-kang-lab/InjecAgent (#{file.name})",
           "source_url" => "https://github.com/uiuc-kang-lab/InjecAgent",
           "license" => "MIT",
           "source_revision" => "f19c9f2c79a41046eb13c03c51a24c567a8ffa07",
           "source_split" => file.split,
           "source_row" => row,
           "upstream_label" => r["Attack Type"],
           "template_id" =>
             "injecagent/" <> String.slice(Nous.Eval.CanonicalJSON.digest(attack), 7, 16)
         }
       )}
    end

    def injecagent(_file, _row, _index), do: :skip

    def jbb(file, %{"Goal" => goal} = r, row) when is_binary(goal) do
      verdict = if file.split == "harmful", do: "block", else: "allow"

      {:ok,
       base("jbb-#{file.split}-#{row}", "user_input", verdict, %{"text" => goal},
         category: r["Category"],
         tags: if(verdict == "allow", do: ["hard_negative"], else: []),
         provenance: %{
           "source" => "JailbreakBench/JBB-Behaviors (#{file.split})",
           "source_url" => "https://huggingface.co/datasets/JailbreakBench/JBB-Behaviors",
           "license" => "MIT",
           "source_revision" => "886acc352a31533ffbcf4ef22c744658688086fc",
           "source_split" => file.split,
           "source_row" => row,
           "upstream_label" => file.split
         }
       )}
    end

    def jbb(_file, _row, _index), do: :skip

    def agentharm(file, %{"id" => id, "prompt" => prompt} = r, _row) when is_binary(prompt) do
      verdict = if file.split == "harmful", do: "block", else: "allow"

      {:ok,
       base("agentharm-#{file.split}-#{id}", "user_input", verdict, %{"text" => prompt},
         category: r["category"],
         provenance: %{
           "source" => "ai-safety-institute/AgentHarm (#{file.name})",
           "source_url" => "https://huggingface.co/datasets/ai-safety-institute/AgentHarm",
           "license" => "LicenseRef-MIT-use-restricted",
           "license_note" =>
             "may not be used for purposes besides improving the safety and security of AI systems",
           "source_revision" => "e23b3fe60a0da9037314b88e5ee3a0c054970dad",
           "source_split" => file.split,
           "source_row" => id,
           "upstream_label" => file.split
         }
       )}
    end

    def agentharm(_file, _row, _index), do: :skip

    defp base(id, surface, label, input, opts) do
      provenance =
        Map.merge(
          %{"public" => true, "label_source" => "upstream"},
          Keyword.fetch!(opts, :provenance)
        )

      %{
        "schema" => "nous.guard_case/1",
        "id" => id,
        "kind" => "classifier",
        "surface" => surface,
        "label" => label,
        "input" => input,
        "provenance" => provenance
      }
      |> put("category", opts[:category])
      |> put("tags", opts[:tags])
    end

    defp put(map, _key, nil), do: map
    defp put(map, _key, []), do: map
    defp put(map, key, value), do: Map.put(map, key, value)

    # InjecAgent writes tool parameters as Python dict literals; the common
    # flat ones convert by swapping quote styles. Anything else is kept raw.
    defp python_dict(nil), do: %{}

    defp python_dict(text) when is_binary(text) do
      case JSON.decode(String.replace(text, "'", "\"")) do
        {:ok, %{} = map} -> map
        _ -> %{"raw" => text}
      end
    end
  end
end
