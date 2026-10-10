import { NextRequest, NextResponse } from "next/server"
import crypto from "crypto"
import { db } from "@/lib/db"
import { decrypt } from "@/lib/crypto"
import { triggerSkill } from "@/lib/opencode-client"

function verifyGithubSignature(body: string, sig: string | null, secret: string): boolean {
  if (!sig) return false
  const expected = `sha256=${crypto.createHmac("sha256", secret).update(body).digest("hex")}`
  return crypto.timingSafeEqual(Buffer.from(sig), Buffer.from(expected))
}

export async function POST(req: NextRequest) {
  const body = await req.text()
  const event = req.headers.get("x-github-event")
  const sig = req.headers.get("x-hub-signature-256")

  if (event !== "pull_request") return NextResponse.json({ ok: true })

  const payload = JSON.parse(body)
  const action: string = payload.action
  if (action !== "opened" && action !== "synchronize") return NextResponse.json({ ok: true })

  const repoUrl: string = payload.repository?.html_url ?? ""
  const prNumber: number = payload.number
  const baseRef: string = payload.pull_request?.base?.ref ? `origin/${payload.pull_request.base.ref}` : "origin/main"
  const headRef: string = payload.pull_request?.head?.sha ?? "HEAD"

  const repo = await db.repo.findFirst({
    where: { repoUrl },
    include: { app: true, config: true, policy: true },
  })
  if (!repo) return NextResponse.json({ ok: true })

  const webhookSecret = decrypt(repo.app.webhookSecretEnc)
  if (!verifyGithubSignature(body, sig, webhookSecret)) {
    return NextResponse.json({ error: "Invalid signature" }, { status: 401 })
  }

  if (repo.status !== "ready") {
    await db.review.create({ data: { repoId: repo.id, prNumber, status: "pending" } })
    return NextResponse.json({ ok: true, note: "repo indexing, review queued" })
  }

  const review = await db.review.create({ data: { repoId: repo.id, prNumber, status: "pending" } })

  if (repo.opencodeServiceUrl) {
    try {
      const sessionId = await triggerSkill({
        serviceUrl: repo.opencodeServiceUrl,
        password: process.env.OPENCODE_AGENT_PASSWORD ?? "changeme",
        agent: "pr-reviewer",
        skillName: "rgctl-pr-reviewer-v2",
        inputJson: {
          repo_url: repo.repoUrl,
          pr_number: prNumber,
          base_ref: baseRef,
          head_ref: headRef,
          github_token: payload.installation ? `installation:${payload.installation.id}` : undefined,
          policy_json: repo.policy?.policyJson,
          config: {
            upstream_depth: repo.config?.upstreamDepth ?? 2,
            downstream_depth: repo.config?.downstreamDepth ?? 1,
            fanout: repo.config?.fanout ?? 10,
            output_mode: repo.config?.outputMode ?? "comment",
          },
        },
      })
      await db.review.update({ where: { id: review.id }, data: { sessionId, status: "running" } })
    } catch (e) {
      console.error("[webhook/github] triggerSkill failed:", e)
      await db.review.update({ where: { id: review.id }, data: { status: "error" } })
    }
  }

  return NextResponse.json({ ok: true })
}
