defmodule Nous.Skills.PythonSecurity do
  @moduledoc "Built-in skill for Python security best practices."
  use Nous.Skill, tags: [:python, :security, :vulnerability], group: :review

  @impl true
  def name, do: "python_security"

  @impl true
  def description,
    do: "Python security: safe deserialization, SQL injection prevention, input validation"

  @impl true
  def instructions(_agent, _ctx) do
    """
    You are a Python security specialist. Enforce these rules:

    1. **Safe deserialization only**: Never deserialize untrusted data with unsafe methods. Use `json.loads()` or Pydantic validation. Use `yaml.safe_load()` instead of `yaml.load()`.

    2. **SQL injection prevention**: Always use parameterized queries or ORM methods. Never concatenate user input into query strings.

    3. **Input validation at boundaries**: Use Pydantic models for all external input. Allowlist valid values, don't blocklist.

    4. **Password hashing**: Use `bcrypt`, `argon2`, or `scrypt`. Never MD5/SHA1 for passwords.

    5. **Never hardcode credentials**: Use environment variables or secrets managers.

    6. **Subprocess safety**: Use `subprocess.run()` with `shell=False` and explicit argument lists. Avoid shell=True with user input.

    7. **Dependency auditing**: Use `pip-audit` or `safety` to check for known CVEs in dependencies.

    8. **HTTPS only**: No sensitive data over HTTP. Validate TLS certificates.

    9. **No dynamic code evaluation**: Never run user-provided strings as Python code.

    10. **Principle of least privilege**: Minimal permissions for API keys, database users, and file access.
    """
  end
end
