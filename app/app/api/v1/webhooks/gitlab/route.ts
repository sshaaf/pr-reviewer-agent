import { NextRequest, NextResponse } from "next/server"
import { db } from "@/lib/db"
import { decrypt } from "@/lib/crypto"
import { triggerSkill } from "@/lib/opencode-client"

export async function POST(req: NextRequest) {
  const event = req.headers.get("x-gitlab-event")
  const token = req.headers.get("x-gitlab-token")

  if (event !== "Merge Request Hook") return NextResponse.json({ ok: true })

  const payload = await req.json()
  const action: string = payload.object_attributes?.action
  if (action !== "open" && action !== "update") return NextResponse.json({ ok: true })

  const repoUrl: string = payload.project?.web_url ?? ""
  const prNumber: number = payload.object_attributes?.iid
  const baseRef = `origin/${payload.object_attributes?.target_branch ?? "main"}`
  const headRef: string = payload.object_attributes?.last_commit?.id ?? "HEAD"

  const repo = await db.repo.findFirst({
    where: { repoUrl },
    include: { app: true, config: true, policy: true },
  })
  if (!repo) return NextResponse.json({ ok: true })

  const webhookSecret = decrypt(repo.app.webhookSecretEnc)
  if (token !== webhookSecret) {
    return NextResponse.json({ error: "Invalid token" }, { status: 401 })
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
          gitlab_token: process.env.GITLAB_PAT,
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
      console.error("[webhook/gitlab] triggerSkill failed:", e)
      await db.review.update({ where: { id: review.id }, data: { status: "error" } })
    }
  }

  return NextResponse.json({ ok: true })
}
