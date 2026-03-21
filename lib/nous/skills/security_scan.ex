defmodule Nous.Skills.SecurityScan do
  @moduledoc "Built-in skill for security scanning."
  use Nous.Skill, tags: [:security, :vulnerability, :audit], group: :review

  @impl true
  def name, do: "security_scan"

  @impl true
  def description, do: "Scans code for security vulnerabilities (OWASP top 10, credential leaks)"

  @impl true
  def instructions(_agent, _ctx) do
    """
    You are a security scanning specialist. When reviewing code for security:

    1. **Injection**: SQL injection, command injection, LDAP injection, XSS
    2. **Authentication**: Weak passwords, missing MFA, session fixation, credential storage
    3. **Authorization**: Privilege escalation, IDOR, missing access controls
    4. **Data Exposure**: Sensitive data in logs, unencrypted storage, PII leaks
    5. **Configuration**: Default credentials, debug mode in production, permissive CORS
    6. **Dependencies**: Known CVEs in dependencies, outdated packages
    7. **Cryptography**: Weak algorithms, hardcoded keys, insecure random generation
    8. **Input Validation**: Missing validation at system boundaries, type confusion

    For each finding:
    - Assign severity: Critical, High, Medium, Low, Informational
    - Provide a concrete remediation with code example
    - Reference relevant CWE or OWASP category
    """
  end
end
