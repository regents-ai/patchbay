# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: first_screen.spec.ts >> on a phone >> every control on /hermes is a full finger tall
- Location: test/browser/first_screen.spec.ts:56:5

# Error details

```
Error: Channel closed
```

```
Error: page.goto: net::ERR_ABORTED at http://127.0.0.1:63004/hermes
Call log:
  - navigating to "http://127.0.0.1:63004/hermes", waiting until "load"

```

```
Error: browserContext._wrapApiCall: Target page, context or browser has been closed
```