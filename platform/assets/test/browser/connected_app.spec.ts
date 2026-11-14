import {createHash, randomBytes} from "node:crypto"
import {expect, signedIn, test, watch} from "./support/test"

// Connecting an app such as Claude at patchbay.help, the way a person does it: the
// app sends them to the approval page, they allow it, and it then shows under Apps
// on their Agents page, where Disconnect asks first and then ends its access.
// patchbay.help's sign-in is switched on for the walk (support/serve.sh).

test.use(signedIn)

test("a person approves an app, sees it under Apps and disconnects it", async ({page, baseURL}, info) => {
  const problems = watch(page)
  // Each screen size connects an app of its own, as they run at once.
  const name = `Claude ${info.project.name}`
  const callback = `${baseURL}/walk-callback`
  const verifier = randomBytes(32).toString("base64url")

  const {resource} = await (await page.request.get("/.well-known/oauth-protected-resource/mcp")).json()

  const registered = await page.request.post("/oauth/register", {
    data: {client_name: name, redirect_uris: [callback]},
  })
  expect(registered.status()).toBe(201)
  const {client_id: clientId} = await registered.json()

  await page.goto(
    "/oauth/authorize?" +
      new URLSearchParams({
        client_id: clientId,
        redirect_uri: callback,
        response_type: "code",
        scope: "regent.identity.manage patchbay.posts.write",
        state: "walk",
        resource,
        code_challenge: createHash("sha256").update(verifier).digest("base64url"),
        code_challenge_method: "S256",
      }),
  )

  await expect(page.getByRole("heading", {level: 1})).toHaveText(`Connect ${name}`)
  const allow = page.getByRole("button", {name: "Allow connection"})
  await expect(allow).toBeVisible()
  await expect(page.getByRole("button", {name: "Cancel"})).toBeVisible()
  await problems.expect()

  // Allowing sends the person back to the app with a code, which it trades for its token.
  await allow.click()
  await page.waitForURL(url => url.pathname === "/walk-callback")
  const code = new URL(page.url()).searchParams.get("code")!

  const token = await page.request.post("/oauth/token", {
    form: {
      grant_type: "authorization_code",
      client_id: clientId,
      code,
      code_verifier: verifier,
      redirect_uri: callback,
      resource,
    },
  })
  expect(token.status()).toBe(200)

  await page.goto("/account/agents")
  await expect(page.locator("[data-phx-main].phx-connected")).toBeAttached()
  const apps = page.locator("#account-agents-apps")
  await expect(apps.getByRole("heading", {name: "Apps"})).toBeVisible()
  await expect(apps.getByText(name, {exact: true})).toBeVisible()
  await problems.expect()

  // Disconnect asks in the site's own window; Cancel keeps the app.
  const disconnect = apps.getByRole("button", {name: `Disconnect ${name}`, exact: true})
  const asking = page.locator("#rg-confirm")
  await disconnect.click()
  await expect(asking).toContainText(`Disconnect ${name}?`)
  await asking.getByRole("button", {name: "Cancel"}).click()
  await expect(asking).toBeHidden()
  await expect(disconnect).toBeVisible()

  await disconnect.click()
  await asking.getByRole("button", {name: "Disconnect", exact: true}).click()
  await expect(apps.getByRole("status")).toHaveText(
    `${name} is disconnected. It needs your approval to connect again.`,
  )
  await expect(disconnect).toHaveCount(0)
  await problems.expect()
})
