defmodule Nous.Skills.PythonTyping do
  @moduledoc "Built-in skill for modern Python type hints, Pydantic, and dataclasses."
  use Nous.Skill, tags: [:python, :typing, :pydantic, :modern], group: :coding

  @impl true
  def name, do: "python_typing"

  @impl true
  def description,
    do: "Modern Python: type hints, Protocol classes, Pydantic vs dataclasses, pattern matching"

  @impl true
  def instructions(_agent, _ctx) do
    """
    You are a modern Python specialist (3.10+). Follow these patterns:

    1. **Type annotations on all public functions**: Use `mypy --strict` compatible annotations:
       ```python
       def process_items(items: list[str], limit: int = 10) -> dict[str, int]:
       ```

    2. **Choose the right data container**:
       - `Pydantic BaseModel`: API boundaries, runtime validation needed
       - `@dataclass`: Internal data, trust input, no validation
       - `TypedDict`: Typed dictionaries without class overhead
       - `Protocol`: Structural subtyping (duck typing with types)

    3. **Protocol classes** for interfaces (not ABC):
       ```python
       class Renderable(Protocol):
           def render(self) -> str: ...
       ```

    4. **Pattern matching** (3.10+) for complex branching:
       ```python
       match command:
           case {"action": "create", "data": data}:
               create(data)
           case {"action": "delete", "id": int(id)}:
               delete(id)
           case _:
               raise ValueError("Unknown command")
       ```

    5. **Use `|` union syntax** (3.10+): `str | None` not `Optional[str]`.

    6. **Pydantic v2 patterns**:
       ```python
       class Config(BaseModel):
           model_config = ConfigDict(validate_assignment=True, from_attributes=True)
       ```

    7. **Naming**: `snake_case` functions/variables, `PascalCase` classes, `UPPER_CASE` constants.

    8. **Google-style docstrings** for all public APIs with type descriptions.
    """
  end

  @impl true
  def match?(input) do
    input = String.downcase(input)

    String.contains?(input, [
      "python type",
      "type hint",
      "pydantic",
      "dataclass",
      "protocol class",
      "pattern matching python",
      "mypy"
    ])
  end
end
