"use client"
import { useEffect, useState } from "react"

type App = { id: string; name: string; provider: string; appId: string; createdAt: string }

export default function AppsAdminPage() {
  const [apps, setApps] = useState<App[]>([])
  const [name, setName] = useState("")
  const [provider, setProvider] = useState("github")
  const [appId, setAppId] = useState("")
  const [privateKey, setPrivateKey] = useState("")
  const [webhookSecret, setWebhookSecret] = useState("")
  const [error, setError] = useState("")

  const load = () => fetch("/api/v1/apps").then(r => r.json()).then(setApps)
  useEffect(() => { load() }, [])

  async function createApp(e: React.FormEvent) {
    e.preventDefault()
    const res = await fetch("/api/v1/apps", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name, provider, appId, privateKey, webhookSecret }),
    })
    if (res.ok) { setName(""); setAppId(""); setPrivateKey(""); setWebhookSecret(""); load() }
    else { const d = await res.json(); setError(d.error ?? "Error") }
  }

  async function deleteApp(id: string) {
    if (!confirm("Delete app registration?")) return
    await fetch(`/api/v1/apps/${id}`, { method: "DELETE" })
    load()
  }

  return (
    <div className="p-8 max-w-3xl mx-auto space-y-8">
      <h1 className="text-2xl font-bold">App Registrations</h1>

      <form onSubmit={createApp} className="space-y-3 bg-white border rounded-lg p-5 shadow-sm">
        <div className="grid grid-cols-2 gap-3">
          <div>
            <label className="block text-sm font-medium mb-1">Name</label>
            <input value={name} onChange={e => setName(e.target.value)} className="w-full border rounded px-3 py-2 text-sm" required />
          </div>
          <div>
            <label className="block text-sm font-medium mb-1">Provider</label>
            <select value={provider} onChange={e => setProvider(e.target.value)} className="w-full border rounded px-3 py-2 text-sm">
              <option value="github">GitHub</option>
              <option value="gitlab">GitLab</option>
            </select>
          </div>
        </div>
        <div>
          <label className="block text-sm font-medium mb-1">App ID</label>
          <input value={appId} onChange={e => setAppId(e.target.value)} className="w-full border rounded px-3 py-2 text-sm" required />
        </div>
        <div>
          <label className="block text-sm font-medium mb-1">Private Key (PEM)</label>
          <textarea value={privateKey} onChange={e => setPrivateKey(e.target.value)} rows={4}
            className="w-full font-mono text-xs border rounded px-3 py-2" required />
        </div>
        <div>
          <label className="block text-sm font-medium mb-1">Webhook Secret</label>
          <input value={webhookSecret} onChange={e => setWebhookSecret(e.target.value)} type="password"
            className="w-full border rounded px-3 py-2 text-sm" required />
        </div>
        {error && <p className="text-red-600 text-sm">{error}</p>}
        <button type="submit" className="bg-blue-600 text-white px-4 py-2 rounded text-sm font-medium hover:bg-blue-700">
          Register App
        </button>
      </form>

      <table className="w-full text-sm border rounded overflow-hidden">
        <thead className="bg-gray-50">
          <tr>
            <th className="px-3 py-2 text-left">Name</th>
            <th className="px-3 py-2 text-left">Provider</th>
            <th className="px-3 py-2 text-left">App ID</th>
            <th />
          </tr>
        </thead>
        <tbody>
          {apps.map(a => (
            <tr key={a.id} className="border-t">
              <td className="px-3 py-2">{a.name}</td>
              <td className="px-3 py-2">{a.provider}</td>
              <td className="px-3 py-2">{a.appId}</td>
              <td className="px-3 py-2">
                <button onClick={() => deleteApp(a.id)} className="text-red-600 text-xs hover:underline">Delete</button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}
