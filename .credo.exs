%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "src/", "test/", "web/"],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/"]
      },
      plugins: [],
      requires: [],
      strict: false,
      parse_timeout: 5000,
      color: true,
      checks: %{
        enabled: [
          ## Consistency Checks
          {Credo.Check.Consistency.ExceptionNames, false},
          {Credo.Check.Consistency.LineEndings, []},
          {Credo.Check.Consistency.ParameterPatternMatching, []},
          # Disabled: credo 1.7.15 crashes on the new Elixir 1.20-rc sigil
          # token format (FunctionClauseError in Credo.Code.Token.position/1).
          # Re-enable once credo ships a fix that supports the new tokens.
          {Credo.Check.Consistency.SpaceAroundOperators, false},
          {Credo.Check.Consistency.SpaceInParentheses, []},
          {Credo.Check.Consistency.TabsOrSpaces, []},

          ## Design Checks
          {Credo.Check.Design.AliasUsage, false},
          {Credo.Check.Design.TagFIXME, []},
          {Credo.Check.Design.TagTODO, false},

          ## Readability Checks
          {Credo.Check.Readability.AliasOrder, false},
          {Credo.Check.Readability.FunctionNames, []},
          {Credo.Check.Readability.LargeNumbers, false},
          {Credo.Check.Readability.MaxLineLength, false},
          {Credo.Check.Readability.ModuleAttributeNames, []},
          {Credo.Check.Readability.ModuleDoc, false},
          {Credo.Check.Readability.ModuleNames, []},
          {Credo.Check.Readability.ParenthesesInCondition, []},
          {Credo.Check.Readability.ParenthesesOnZeroArityDefs, []},
          {Credo.Check.Readability.PipeIntoAnonymousFunctions, []},
          {Credo.Check.Readability.PredicateFunctionNames, false},
          {Credo.Check.Readability.PreferImplicitTry, false},
          {Credo.Check.Readability.RedundantBlankLines, []},
          {Credo.Check.Readability.Semicolons, []},
          {Credo.Check.Readability.SpaceAfterCommas, []},
          {Credo.Check.Readability.StringSigils, false},
          {Credo.Check.Readability.TrailingBlankLine, []},
          {Credo.Check.Readability.TrailingWhiteSpace, []},
          {Credo.Check.Readability.UnnecessaryAliasExpansion, []},
          {Credo.Check.Readability.VariableNames, []},
          {Credo.Check.Readability.WithSingleClause, false},

          ## Refactoring Opportunities
          {Credo.Check.Refactor.Apply, false},
          {Credo.Check.Refactor.CondStatements, false},
          # At Credo's default of 9 since the 2026-08 audit (arch F-3). The
          # relaxed 23 was a threshold artifact: `mix credo --strict` reported
          # zero while 30 functions exceeded the default. Only ever move DOWN.
          {Credo.Check.Refactor.CyclomaticComplexity, []},
          {Credo.Check.Refactor.FilterCount, []},
          {Credo.Check.Refactor.FilterFilter, []},
          # At Credo's default of 8 since the 2026-08 audit. The three
          # 14-positional-arg optimizer helpers that pinned this at 14 are gone —
          # the shared trial loop lives in Nous.Eval.Optimizer now. Only DOWN.
          {Credo.Check.Refactor.FunctionArity, []},
          {Credo.Check.Refactor.LongQuoteBlocks, false},
          {Credo.Check.Refactor.MapJoin, false},
          {Credo.Check.Refactor.MatchInCondition, []},
          {Credo.Check.Refactor.NegatedConditionsInUnless, []},
          {Credo.Check.Refactor.NegatedConditionsWithElse, []},
          # At Credo's default of 2 since the 2026-08 audit. The optimizer
          # strategy bodies that pinned this at 5 were flattened when their
          # shared trial loop was hoisted. Only ever move this DOWN.
          {Credo.Check.Refactor.Nesting, []},
          {Credo.Check.Refactor.RedundantWithClauseResult, false},
          {Credo.Check.Refactor.RejectReject, []},
          {Credo.Check.Refactor.UnlessWithElse, false},
          {Credo.Check.Refactor.WithClauses, []},

          ## Warnings — these catch real bugs, keep them on
          {Credo.Check.Warning.ApplicationConfigInModuleAttribute, []},
          {Credo.Check.Warning.BoolOperationOnSameValues, []},
          {Credo.Check.Warning.Dbg, []},
          {Credo.Check.Warning.ExpensiveEmptyEnumCheck, false},
          {Credo.Check.Warning.IExPry, []},
          {Credo.Check.Warning.IoInspect, []},
          {Credo.Check.Warning.MissedMetadataKeyInLoggerConfig, []},
          {Credo.Check.Warning.OperationOnSameValues, []},
          {Credo.Check.Warning.OperationWithConstantResult, []},
          {Credo.Check.Warning.RaiseInsideRescue, []},
          {Credo.Check.Warning.SpecWithStruct, []},
          {Credo.Check.Warning.StructFieldAmount, []},
          {Credo.Check.Warning.UnsafeExec, []},
          {Credo.Check.Warning.UnusedEnumOperation, []},
          {Credo.Check.Warning.UnusedFileOperation, []},
          {Credo.Check.Warning.UnusedKeywordOperation, []},
          {Credo.Check.Warning.UnusedListOperation, []},
          {Credo.Check.Warning.UnusedPathOperation, []},
          {Credo.Check.Warning.UnusedRegexOperation, []},
          {Credo.Check.Warning.UnusedStringOperation, []},
          {Credo.Check.Warning.UnusedTupleOperation, []},
          {Credo.Check.Warning.WrongTestFileExtension, []},

          ## Enabled at the 2026-08 audit (arch F-3), each scoped deliberately.
          #
          # Specs earn their keep on the semver surface. `test/` is excluded: a
          # @spec on a test helper documents nothing to a consumer, and a wrong
          # spec is worse than none because dialyzer runs in CI.
          {Credo.Check.Readability.Specs, files: %{excluded: ["test/"]}},
          # Was disabled, which hid six clusters (now collapsed — see
          # Nous.Eval.Optimizer's shared trial loop, Nous.HTTP.StreamBackend
          # .Chunking, Nous.Memory.Store.{Results,Columns} and engine.ex's
          # choose_edge/2). Two exclusions, both deliberate:
          #   - the two DuckDB stores: their column allowlists MUST stay
          #     disjoint or the sec F-5 identifier-injection hole reopens. Both
          #     files carry a comment saying so above the flagged block.
          #   - test/: explicitness beats DRY in a test.
          {Credo.Check.Design.DuplicatedCode,
           files: %{
             excluded: [
               "test/",
               "lib/nous/memory/store/duckdb.ex",
               "lib/nous/decisions/store/duckdb.ex"
             ]
           }},
        ],
        disabled: [
          {Credo.Check.Refactor.UtcNowTruncate, []},
          {Credo.Check.Consistency.MultiAliasImportRequireUse, []},
          {Credo.Check.Consistency.UnusedVariableNames, []},
          {Credo.Check.Design.SkipTestWithoutComment, []},
          {Credo.Check.Readability.AliasAs, []},
          {Credo.Check.Readability.BlockPipe, []},
          {Credo.Check.Readability.ImplTrue, []},
          {Credo.Check.Readability.MultiAlias, []},
          {Credo.Check.Readability.NestedFunctionCalls, []},
          {Credo.Check.Readability.OneArityFunctionInPipe, []},
          {Credo.Check.Readability.OnePipePerLine, []},
          {Credo.Check.Readability.SeparateAliasRequire, []},
          {Credo.Check.Readability.SingleFunctionToBlockPipe, []},
          {Credo.Check.Readability.SinglePipe, []},
          {Credo.Check.Readability.StrictModuleLayout, []},
          {Credo.Check.Readability.WithCustomTaggedTuple, []},
          {Credo.Check.Refactor.ABCSize, []},
          {Credo.Check.Refactor.AppendSingleItem, []},
          {Credo.Check.Refactor.DoubleBooleanNegation, []},
          {Credo.Check.Refactor.FilterReject, []},
          {Credo.Check.Refactor.IoPuts, []},
          {Credo.Check.Refactor.MapMap, []},
          {Credo.Check.Refactor.ModuleDependencies, []},
          {Credo.Check.Refactor.NegatedIsNil, []},
          {Credo.Check.Refactor.PassAsyncInTestCases, []},
          {Credo.Check.Refactor.PipeChainStart, []},
          {Credo.Check.Refactor.RejectFilter, []},
          {Credo.Check.Refactor.VariableRebinding, []},
          {Credo.Check.Warning.LazyLogging, []},
          {Credo.Check.Warning.LeakyEnvironment, []},
          {Credo.Check.Warning.MapGetUnsafePass, []},
          {Credo.Check.Warning.MixEnv, []},
          {Credo.Check.Warning.UnsafeToAtom, []}
        ]
      }
    }
  ]
}
