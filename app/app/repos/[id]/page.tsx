"use client"
import { useEffect, useState } from "react"
import { useParams, useRouter } from "next/navigation"

type Review = { id: string; prNumber: number; status: string; createdAt: string }

export default function RepoDetailPage() {
  const { id } = useParams<{ id: string }>()
  const router = useRouter()
  const [repo, setRepo] = useState<any>(null)
  const [policy, setPolicy] = useState("")
  const [reviews, setReviews] = useState<Review[]>([])
  const [saving, setSaving] = useState(false)
  const [msg, setMsg] = useState("")

  useEffect(() => {
    fetch(`/api/v1/repos/${id}`).then(r => r.json()).then(setRepo)
    fetch(`/api/v1/repos/${id}/policy`).then(r => r.json()).then(p => setPolicy(p?.policyJson ?? ""))
    fetch(`/api/v1/repos/${id}/reviews`).then(r => r.json()).then(setReviews)
  }, [id])

  async function savePolicy() {
    setSaving(true)
    const res = await fetch(`/api/v1/repos/${id}/policy`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: policy,
    })
    setSaving(false)
    setMsg(res.ok ? "Policy saved." : "Invalid JSON")
    setTimeout(() => setMsg(""), 3000)
  }

  async function deleteRepo() {
    if (!confirm("Delete this repository and all its data?")) return
    await fetch(`/api/v1/repos/${id}`, { method: "DELETE" })
    router.push("/repos")
  }

  if (!repo) return <div className="p-8 text-gray-500">Loading…</div>

  return (
    <div className="p-8 max-w-3xl mx-auto space-y-8">
      <div>
        <h1 className="text-2xl font-bold">{repo.repoUrl?.replace("https://", "")}</h1>
        <p className="text-sm text-gray-500 mt-1">Status: <span className="font-medium">{repo.status?.toUpperCase()}</span></p>
      </div>

      <section>
        <h2 className="text-lg font-semibold mb-3">Policy (policy.json)</h2>
        <textarea
          value={policy}
          onChange={e => setPolicy(e.target.value)}
          rows={12}
          className="w-full font-mono text-sm border rounded p-3 focus:outline-none focus:ring-2 focus:ring-blue-500"
          placeholder='{ "schema_version": "2", "rules": [] }'
        />
        <div className="flex items-center gap-3 mt-2">
          <button onClick={savePolicy} disabled={saving}
            className="bg-blue-600 text-white px-4 py-2 rounded text-sm font-medium hover:bg-blue-700 disabled:opacity-50">
            {saving ? "Saving…" : "Save Policy"}
          </button>
          {msg && <span className="text-sm text-gray-600">{msg}</span>}
        </div>
      </section>

      <section>
        <h2 className="text-lg font-semibold mb-3">Recent Reviews</h2>
        {reviews.length === 0 ? (
          <p className="text-gray-500 text-sm">No reviews yet.</p>
        ) : (
          <table className="w-full text-sm border rounded overflow-hidden">
            <thead className="bg-gray-50">
              <tr>
                <th className="px-3 py-2 text-left">PR #</th>
                <th className="px-3 py-2 text-left">Status</th>
                <th className="px-3 py-2 text-left">Created</th>
              </tr>
            </thead>
            <tbody>
              {reviews.map(r => (
                <tr key={r.id} className="border-t">
                  <td className="px-3 py-2">#{r.prNumber}</td>
                  <td className="px-3 py-2">{r.status}</td>
                  <td className="px-3 py-2">{new Date(r.createdAt).toLocaleString()}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>

      <section>
        <button onClick={deleteRepo}
          className="text-red-600 border border-red-300 px-4 py-2 rounded text-sm hover:bg-red-50">
          Delete Repository
        </button>
      </section>
    </div>
  )
}
