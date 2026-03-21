---
name: security_checklist
description: Security review checklist for web applications
tags: [security, review]
group: review
activation: manual
allowed_tools: [read_file, grep]
priority: 75
---

When reviewing code for security:
1. Check for SQL injection vulnerabilities
2. Validate and sanitize all user inputs
3. Ensure proper authentication and authorization
4. Look for hardcoded secrets or credentials
5. Verify CORS and CSP headers are configured
6. Check for path traversal vulnerabilities
