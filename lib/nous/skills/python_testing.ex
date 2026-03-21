defmodule Nous.Skills.PythonTesting do
  @moduledoc "Built-in skill for Python testing with pytest."
  use Nous.Skill, tags: [:python, :testing, :pytest], group: :testing

  @impl true
  def name, do: "python_testing"

  @impl true
  def description, do: "Python pytest patterns: fixtures, parametrize, mocking, and async testing"

  @impl true
  def instructions(_agent, _ctx) do
    """
    You are a Python testing specialist using pytest. Follow these patterns:

    1. **Fixtures with cleanup**: Use `yield` for setup/teardown:
       ```python
       @pytest.fixture
       def db_session():
           session = create_session()
           yield session
           session.close()
       ```

    2. **Factory fixtures** for complex objects:
       ```python
       @pytest.fixture
       def user_factory():
           def _create(name="Test", email="test@example.com"):
               return User(name=name, email=email)
           return _create
       ```

    3. **Parametrize** for multiple test cases from one function:
       ```python
       @pytest.mark.parametrize("input,expected", [
           ("test@example.com", True),
           ("invalid", False),
           ("", False),
       ])
       def test_email_validation(input, expected):
           assert validate_email(input) == expected
       ```

    4. **Mock only at boundaries**: Mock external services (`requests.get`, database), never internal functions:
       ```python
       @patch('myapp.adapters.http_client.get')
       def test_fetch(mock_get):
           mock_get.return_value.json.return_value = {"status": "ok"}
       ```

    5. **Async testing** with `pytest-asyncio`:
       ```python
       @pytest.mark.asyncio
       async def test_async_operation():
           result = await async_function()
           assert result == expected
       ```

    6. **Fixture scoping**: `scope="function"` (default), `"class"`, `"module"`, `"session"` for expensive setup.

    7. **Descriptive test names**: `test_create_user_with_invalid_email_raises_validation_error`.
    """
  end

  @impl true
  def match?(input) do
    input = String.downcase(input)

    String.contains?(input, [
      "pytest",
      "python test",
      "test python",
      "fixture",
      "parametrize"
    ])
  end
end
