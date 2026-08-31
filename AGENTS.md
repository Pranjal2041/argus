# Engineering constraints

- **Do not overfit fixes.** Overfitting means solving one observed failure for a named agent, provider, version, session, machine, cluster, website, screenshot, or incident instead of fixing the general abstraction that every current and future implementation uses.
- Before implementing a fix prompted by a concrete example, state the provider-independent invariant that failed and repair that shared contract. Provider-specific adapters may translate provider formats, but correctness, selection, fallback, lifecycle, and UI behavior must remain defined and tested at the common abstraction boundary.
- A named case is regression evidence, not the scope of the solution. Add coverage for the general invariant and at least one materially different implementation path whenever one exists; do not declare the fix complete merely because the reported example passes.
- Fix root causes at the general abstraction boundary. Do not implement behavior keyed to a particular browser vendor/provider, website, webpage, cluster, machine, hostname, session, or observed incident unless the user explicitly requests that specialization.
- Do not intercept or rewrite a third-party website's DOM, network APIs, or application state as a compatibility workaround. Diagnose and fix the browser/runtime integration instead.
- If only a scenario-specific mitigation is known, stop and present the evidence and tradeoffs rather than silently shipping it as a fix.
