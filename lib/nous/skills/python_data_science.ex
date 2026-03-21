defmodule Nous.Skills.PythonDataScience do
  @moduledoc "Built-in skill for Python data science with pandas, NumPy, and scikit-learn."
  use Nous.Skill, tags: [:python, :data_science, :pandas, :numpy, :ml], group: :coding

  @impl true
  def name, do: "python_data_science"

  @impl true
  def description, do: "Pandas, NumPy, scikit-learn patterns and data pipeline best practices"

  @impl true
  def instructions(_agent, _ctx) do
    """
    You are a Python data science specialist. Follow these patterns:

    1. **Pandas — method chaining** for readable transformations:
       ```python
       result = (df
           .query("age > 18")
           .groupby("category")
           .agg({"value": "mean"})
           .sort_values("value", ascending=False)
       )
       ```

    2. **Vectorized operations always**: Never use explicit Python loops on DataFrames:
       ```python
       # Right: df["doubled"] = df["value"] * 2
       # Wrong: [x*2 for x in df["value"]]
       ```

    3. **Categorical types** for low-cardinality string columns: `df["cat"] = df["cat"].astype("category")`

    4. **scikit-learn Pipeline** to prevent data leakage:
       ```python
       pipeline = Pipeline([
           ('scaler', StandardScaler()),
           ('model', LogisticRegression())
       ])
       score = cross_val_score(pipeline, X, y, cv=5)
       ```

    5. **Always split before preprocessing**: Fit preprocessing on train set only, transform both.

    6. **Use `loc`/`iloc` for indexing**: Explicit is better than implicit.

    7. **NumPy broadcasting**: Leverage shape rules instead of manual expansion.

    8. **Memory optimization**: Use appropriate dtypes (`int32` vs `int64`), `category` for strings, chunked reading for large files.

    9. **Reproducibility**: Set random seeds, version your data, log hyperparameters.
    """
  end

  @impl true
  def match?(input) do
    input = String.downcase(input)

    String.contains?(input, [
      "pandas",
      "numpy",
      "dataframe",
      "scikit",
      "sklearn",
      "data science",
      "machine learning",
      "ml pipeline"
    ])
  end
end
