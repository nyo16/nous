defmodule Nous.Skills.PythonFastAPI do
  @moduledoc "Built-in skill for FastAPI and async Python web development."
  use Nous.Skill, tags: [:python, :fastapi, :api, :async, :web], group: :coding

  @impl true
  def name, do: "python_fastapi"

  @impl true
  def description, do: "FastAPI patterns, async Python, Pydantic validation, and API design"

  @impl true
  def instructions(_agent, _ctx) do
    """
    You are a FastAPI and async Python specialist. Follow these patterns:

    1. **Use `async def` for I/O-bound operations**: Database, HTTP calls, file I/O. Use plain `def` only for CPU-bound pure functions.

    2. **RORO pattern**: Receive an Object, Return an Object — use Pydantic models, not dicts:
       ```python
       class UserCreate(BaseModel):
           email: str = Field(..., description="User email")
           age: int = Field(ge=0, le=150)

       @router.post("/users", response_model=UserResponse)
       async def create_user(user: UserCreate, db: Session = Depends(get_db)):
           return await UserService.create(db, user)
       ```

    3. **Dependency injection with `Depends()`**: For database sessions, auth, rate limiting.

    4. **Lifespan context managers** (not deprecated `@app.on_event`):
       ```python
       @asynccontextmanager
       async def lifespan(app: FastAPI):
           await startup()
           yield
           await shutdown()
       ```

    5. **Use `httpx` for async HTTP**, never `requests` in async code.

    6. **Structured concurrency** with `asyncio.TaskGroup` (Python 3.11+):
       ```python
       async with asyncio.TaskGroup() as tg:
           task1 = tg.create_task(fetch_user(1))
           task2 = tg.create_task(fetch_user(2))
       ```

    7. **Rate limit with `asyncio.Semaphore`**: Control concurrent external API calls.

    8. **Guard clauses first**: Handle error conditions at function start with early returns, not nested if/else.
    """
  end

  @impl true
  def match?(input) do
    input = String.downcase(input)

    String.contains?(input, [
      "fastapi",
      "fast api",
      "python api",
      "pydantic",
      "async python",
      "asyncio",
      "uvicorn"
    ])
  end
end
