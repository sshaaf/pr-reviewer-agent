"use client"
import { useState, useEffect } from "react"
import { useRouter } from "next/navigation"

type App = { id: string; name: string; provider: string }

export default function NewRepoPage() {
  const router = useRouter()
  const [apps, setApps] = useState<App[]>([])
  const [repoUrl, setRepoUrl] = useState("")
  const [appId, setAppId] = useState("")
  const [upstreamDepth, setUpstreamDepth] = useState(2)
  const [downstreamDepth, setDownstreamDepth] = useState(1)
  const [outputMode, setOutputMode] = useState("comment")
  const [error, setError] = useState("")
  const [loading, setLoading] = useState(false)

  useEffect(() => {
    fetch("/api/v1/apps").then(r => r.json()).then(data => {
      setApps(data)
      if (data[0]) setAppId(data[0].id)
    })
  }, [])

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    setLoading(true)
    setError("")
    const res = await fetch("/api/v1/repos", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        repoUrl, appId,
        config: { upstream_depth: upstreamDepth, downstream_depth: downstreamDepth, output_mode: outputMode },
      }),
    })
    setLoading(false)
    if (res.ok) {
      router.push("/repos")
    } else {
      const data = await res.json()
      setError(data.error ?? "Failed to add repo")
    }
  }

  return (
    <div className="p-8 max-w-lg mx-auto">
      <h1 className="text-2xl font-bold mb-6">Add Repository</h1>
      <form onSubmit={handleSubmit} className="space-y-4 bg-white border rounded-lg p-6 shadow-sm">
        <div>
          <label className="block text-sm font-medium mb-1">Repository URL</label>
          <input
            type="url" value={repoUrl} onChange={e => setRepoUrl(e.target.value)}
            placeholder="https://github.com/org/repo"
            className="w-full border rounded px-3 py-2 text-sm"
            required
          />
        </div>
        <div>
          <label className="block text-sm font-medium mb-1">GitHub / GitLab App</label>
          <select value={appId} onChange={e => setAppId(e.target.value)} className="w-full border rounded px-3 py-2 text-sm">
            {apps.map(a => <option key={a.id} value={a.id}>{a.name} ({a.provider})</option>)}
          </select>
        </div>
        <div className="grid grid-cols-2 gap-3">
          <div>
            <label className="block text-sm font-medium mb-1">Upstream depth</label>
            <input type="number" min={1} max={5} value={upstreamDepth} onChange={e => setUpstreamDepth(+e.target.value)}
              className="w-full border rounded px-3 py-2 text-sm" />
          </div>
          <div>
            <label className="block text-sm font-medium mb-1">Downstream depth</label>
            <input type="number" min={1} max={5} value={downstreamDepth} onChange={e => setDownstreamDepth(+e.target.value)}
              className="w-full border rounded px-3 py-2 text-sm" />
          </div>
        </div>
        <div>
          <label className="block text-sm font-medium mb-1">Output mode</label>
          <select value={outputMode} onChange={e => setOutputMode(e.target.value)} className="w-full border rounded px-3 py-2 text-sm">
            <option value="comment">PR Comment</option>
            <option value="check_run">Check Run</option>
            <option value="both">Both</option>
          </select>
        </div>
        {error && <p className="text-red-600 text-sm">{error}</p>}
        <div className="flex gap-3">
          <button type="submit" disabled={loading}
            className="flex-1 bg-blue-600 text-white py-2 rounded font-medium hover:bg-blue-700 disabled:opacity-50">
            {loading ? "Adding…" : "Add Repository"}
          </button>
          <button type="button" onClick={() => router.back()}
            className="px-4 py-2 border rounded text-sm hover:bg-gray-50">
            Cancel
          </button>
        </div>
      </form>
    </div>
  )
}
