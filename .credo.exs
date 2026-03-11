%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "src/", "web/", "apps/", "config/", "mix.exs"],
        excluded: [~r"/test/support/", ~r"/deps/", ~r"/_build/"]
      },
      strict: true,
      color: true,
      checks: [
        {Credo.Check.Design.AliasUsage, false},
        {Credo.Check.Readability.ModuleDoc, false},
        {Credo.Check.Refactor.CondStatements, false},
        {Credo.Check.Refactor.CyclomaticComplexity, false},
        {Credo.Check.Refactor.FunctionArity, false},
        {Credo.Check.Refactor.NegatedConditionsWithElse, false},
        {Credo.Check.Refactor.Nesting, false},
        {Credo.Check.Refactor.UnlessWithElse, false}
      ]
    }
  ]
}
