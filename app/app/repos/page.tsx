"use client"
import { useEffect, useState, useCallback } from "react"
import Link from "next/link"

type Repo = {
  id: string
  repoUrl: string
  status: "indexing" | "ready" | "error"
  lastIndexedAt: string | null
  indexError: string | null
}

const statusColors = {
  indexing: "bg-yellow-100 text-yellow-800",
  ready: "bg-green-100 text-green-800",
  error: "bg-red-100 text-red-800",
}

export default function ReposPage() {
  const [repos, setRepos] = useState<Repo[]>([])
  const [loading, setLoading] = useState(true)

  const fetchRepos = useCallback(async () => {
    const res = await fetch("/api/v1/repos")
    if (res.ok) setRepos(await res.json())
  }, [])

  useEffect(() => {
    fetchRepos().finally(() => setLoading(false))
    // Poll every 5s while any repo is indexing
    const id = setInterval(() => {
      setRepos(prev => {
        if (prev.some(r => r.status === "indexing")) fetchRepos()
        return prev
      })
    }, 5000)
    return () => clearInterval(id)
  }, [fetchRepos])

  async function handleReindex(id: string) {
    await fetch(`/api/v1/repos/${id}/reindex`, { method: "POST" })
    fetchRepos()
  }

  if (loading) return <div className="p-8 text-gray-500">Loading…</div>

  return (
    <div className="p-8 max-w-4xl mx-auto">
      <div className="flex items-center justify-between mb-6">
        <h1 className="text-2xl font-bold">Repositories</h1>
        <Link href="/repos/new" className="bg-blue-600 text-white px-4 py-2 rounded text-sm font-medium hover:bg-blue-700">
          + Add repo
        </Link>
      </div>

      {repos.length === 0 && (
        <p className="text-gray-500 text-center py-12">No repositories yet. Add one to get started.</p>
      )}

      <div className="space-y-3">
        {repos.map(repo => (
          <div key={repo.id} className="border rounded-lg p-4 bg-white shadow-sm flex items-center justify-between">
            <div>
              <Link href={`/repos/${repo.id}`} className="font-medium text-blue-700 hover:underline">
                {repo.repoUrl.replace("https://", "")}
              </Link>
              <div className="flex items-center gap-2 mt-1">
                <span className={`text-xs font-medium px-2 py-0.5 rounded ${statusColors[repo.status]}`}>
                  {repo.status.toUpperCase()}
                </span>
                {repo.status === "indexing" && (
                  <span className="text-xs text-gray-500">Building code graph…</span>
                )}
                {repo.status === "ready" && repo.lastIndexedAt && (
                  <span className="text-xs text-gray-500">
                    Last indexed: {new Date(repo.lastIndexedAt).toLocaleString()}
                  </span>
                )}
                {repo.status === "error" && (
                  <span className="text-xs text-red-600 truncate max-w-xs">{repo.indexError}</span>
                )}
              </div>
            </div>
            <div className="flex gap-2">
              {repo.status === "error" && (
                <button
                  onClick={() => handleReindex(repo.id)}
                  className="text-xs border border-red-300 text-red-700 px-3 py-1 rounded hover:bg-red-50"
                >
                  Retry
                </button>
              )}
              <Link href={`/repos/${repo.id}`}
                className="text-xs border px-3 py-1 rounded hover:bg-gray-50 text-gray-600"
              >
                Settings
              </Link>
            </div>
          </div>
        ))}
      </div>
    </div>
  )
}
