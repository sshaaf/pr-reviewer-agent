interface PromptAsyncOptions {
  serviceUrl: string
  password: string
  agent: string
  skillName: string
  inputJson: Record<string, unknown>
}

export async function triggerSkill(opts: PromptAsyncOptions): Promise<string> {
  const auth = Buffer.from(`opencode:${opts.password}`).toString("base64")
  const headers = { "Content-Type": "application/json", Authorization: `Basic ${auth}` }

  const sessionRes = await fetch(`${opts.serviceUrl}/session`, {
    method: "POST", headers, body: JSON.stringify({}),
  })
  if (!sessionRes.ok) throw new Error(`session creation failed: ${sessionRes.status}`)
  const session = await sessionRes.json()
  const sessionId: string = session.id ?? session.session?.id
  if (!sessionId) throw new Error("no session id in response")

  const promptText =
    `Load skill ${opts.skillName} and execute it.\n\nInput JSON:\n${JSON.stringify(opts.inputJson, null, 2)}`

  const promptRes = await fetch(`${opts.serviceUrl}/session/${sessionId}/prompt_async`, {
    method: "POST",
    headers,
    body: JSON.stringify({ agent: opts.agent, parts: [{ type: "text", text: promptText }] }),
  })
  if (!promptRes.ok && promptRes.status !== 204) {
    throw new Error(`prompt_async failed: ${promptRes.status}`)
  }
  return sessionId
}
