import * as k8s from "@kubernetes/client-node"
import { Repo } from "@prisma/client"
import { db } from "./db"

const kc = new k8s.KubeConfig()
kc.loadFromDefault()

const appsApi = kc.makeApiClient(k8s.AppsV1Api)
const coreApi = kc.makeApiClient(k8s.CoreV1Api)
const batchApi = kc.makeApiClient(k8s.BatchV1Api)

const NS = process.env.NAMESPACE ?? "pr-reviewer"
const AGENT_IMAGE = process.env.AGENT_IMAGE ?? "pr-reviewer-agent:latest"
const AGENT_PASSWORD = process.env.OPENCODE_AGENT_PASSWORD ?? "changeme"
const STORAGE_CLASS = process.env.STORAGE_CLASS ?? ""

function repoSlug(repo: Repo): string {
  return repo.id.slice(0, 12)
}

export async function createAgentResources(repo: Repo): Promise<{ deploymentName: string; serviceUrl: string }> {
  const slug = repoSlug(repo)
  const name = `agent-${slug}`
  const pvcName = `agent-db-${slug}`

  // PVC for rgctl graph DB
  await coreApi.createNamespacedPersistentVolumeClaim({
    namespace: NS,
    body: {
      metadata: { name: pvcName, labels: { app: "pr-reviewer-agent", repo: slug } },
      spec: {
        accessModes: ["ReadWriteOnce"],
        resources: { requests: { storage: "5Gi" } },
        ...(STORAGE_CLASS ? { storageClassName: STORAGE_CLASS } : {}),
      },
    },
  }).catch((e) => { if (e.statusCode !== 409) throw e })

  // Deployment
  await appsApi.createNamespacedDeployment({
    namespace: NS,
    body: {
      metadata: { name, labels: { app: "pr-reviewer-agent", repo: slug } },
      spec: {
        replicas: 1,
        selector: { matchLabels: { app: "pr-reviewer-agent", repo: slug } },
        template: {
          metadata: { labels: { app: "pr-reviewer-agent", repo: slug } },
          spec: {
            serviceAccountName: "pr-reviewer",
            securityContext: { runAsUser: 1001, runAsGroup: 0, fsGroup: 0 },
            volumes: [
              { name: "rgctl-db", persistentVolumeClaim: { claimName: pvcName } },
              { name: "tmp", emptyDir: {} },
            ],
            containers: [{
              name: "agent",
              image: AGENT_IMAGE,
              ports: [{ containerPort: 4096 }],
              env: [
                { name: "OPENCODE_SERVER_PASSWORD", value: AGENT_PASSWORD },
                { name: "REPO_URL", value: repo.repoUrl },
                { name: "RGCTL_DB", value: "/app/rgctl-db" },
              ],
              envFrom: [{ secretRef: { name: "pr-reviewer-llm-keys", optional: true } }],
              volumeMounts: [
                { name: "rgctl-db", mountPath: "/app/rgctl-db" },
                { name: "tmp", mountPath: "/tmp" },
              ],
              readinessProbe: {
                httpGet: { path: "/global/health", port: 4096 },
                initialDelaySeconds: 15,
                periodSeconds: 10,
              },
              resources: {
                requests: { cpu: "250m", memory: "512Mi" },
                limits: { cpu: "2", memory: "2Gi" },
              },
            }],
          },
        },
      },
    },
  }).catch((e) => { if (e.statusCode !== 409) throw e })

  // Service
  await coreApi.createNamespacedService({
    namespace: NS,
    body: {
      metadata: { name, labels: { app: "pr-reviewer-agent", repo: slug } },
      spec: {
        selector: { app: "pr-reviewer-agent", repo: slug },
        ports: [{ port: 4096, targetPort: 4096 }],
      },
    },
  }).catch((e) => { if (e.statusCode !== 409) throw e })

  return {
    deploymentName: name,
    serviceUrl: `http://${name}.${NS}.svc:4096`,
  }
}

export async function deleteAgentResources(repo: Repo): Promise<void> {
  const slug = repoSlug(repo)
  const name = `agent-${slug}`
  const pvcName = `agent-db-${slug}`

  await appsApi.deleteNamespacedDeployment({ name, namespace: NS }).catch(() => {})
  await coreApi.deleteNamespacedService({ name, namespace: NS }).catch(() => {})
  await coreApi.deleteNamespacedPersistentVolumeClaim({ name: pvcName, namespace: NS }).catch(() => {})
}

export async function createDiscoverJob(repo: Repo): Promise<string> {
  const slug = repoSlug(repo)
  const jobName = `discover-${slug}-${Date.now()}`
  const pvcName = `agent-db-${slug}`

  await batchApi.createNamespacedJob({
    namespace: NS,
    body: {
      metadata: { name: jobName, labels: { app: "pr-reviewer-discover", repo: slug } },
      spec: {
        backoffLimit: 2,
        ttlSecondsAfterFinished: 3600,
        template: {
          metadata: { labels: { app: "pr-reviewer-discover", repo: slug } },
          spec: {
            restartPolicy: "OnFailure",
            securityContext: { runAsUser: 1001, runAsGroup: 0, fsGroup: 0 },
            volumes: [
              { name: "rgctl-db", persistentVolumeClaim: { claimName: pvcName } },
              { name: "tmp", emptyDir: {} },
              { name: "repo", emptyDir: {} },
            ],
            containers: [{
              name: "discover",
              image: AGENT_IMAGE,
              command: ["/bin/sh", "-c"],
              args: [`
                set -e
                git clone --filter=blob:none "${repo.repoUrl}" /app/repo
                cd /app/repo
                rgctl discover . --with-cfg --db /app/rgctl-db
              `],
              env: [{ name: "RGCTL_DB", value: "/app/rgctl-db" }],
              volumeMounts: [
                { name: "rgctl-db", mountPath: "/app/rgctl-db" },
                { name: "tmp", mountPath: "/tmp" },
                { name: "repo", mountPath: "/app/repo" },
              ],
              resources: {
                requests: { cpu: "500m", memory: "1Gi" },
                limits: { cpu: "4", memory: "4Gi" },
              },
            }],
          },
        },
      },
    },
  })

  watchDiscoverJob(jobName, repo.id)
  return jobName
}

function watchDiscoverJob(jobName: string, repoId: string) {
  const poll = setInterval(async () => {
    try {
      const job = await batchApi.readNamespacedJob({ name: jobName, namespace: NS })
      const status = job.status

      if (status?.succeeded && status.succeeded > 0) {
        clearInterval(poll)
        await db.repo.update({
          where: { id: repoId },
          data: { status: "ready", lastIndexedAt: new Date(), indexError: null },
        })
      } else if (status?.failed && status.failed >= 3) {
        clearInterval(poll)
        const podList = await coreApi.listNamespacedPod({ namespace: NS, labelSelector: `job-name=${jobName}` })
        const podName = podList.items[0]?.metadata?.name
        let logTail = ""
        if (podName) {
          try {
            const logs = await coreApi.readNamespacedPodLog({ name: podName, namespace: NS, tailLines: 50 })
            logTail = typeof logs === "string" ? logs : ""
          } catch {}
        }
        await db.repo.update({
          where: { id: repoId },
          data: { status: "error", indexError: logTail || "Discover job failed" },
        })
      }
    } catch (e) {
      console.error(`[k8s] watchDiscoverJob ${jobName} poll error:`, e)
    }
  }, 10_000)
}

export async function createReindexCronJob(repo: Repo, schedule: string): Promise<void> {
  const slug = repoSlug(repo)
  const name = `reindex-${slug}`
  const pvcName = `agent-db-${slug}`

  await batchApi.createNamespacedCronJob({
    namespace: NS,
    body: {
      metadata: { name, labels: { app: "pr-reviewer-reindex", repo: slug } },
      spec: {
        schedule,
        concurrencyPolicy: "Forbid",
        jobTemplate: {
          spec: {
            backoffLimit: 1,
            template: {
              metadata: { labels: { app: "pr-reviewer-reindex", repo: slug } },
              spec: {
                restartPolicy: "OnFailure",
                securityContext: { runAsUser: 1001, runAsGroup: 0, fsGroup: 0 },
                volumes: [
                  { name: "rgctl-db", persistentVolumeClaim: { claimName: pvcName } },
                  { name: "tmp", emptyDir: {} },
                  { name: "repo", emptyDir: {} },
                ],
                containers: [{
                  name: "reindex",
                  image: AGENT_IMAGE,
                  command: ["/bin/sh", "-c"],
                  args: [`
                    set -e
                    git clone --filter=blob:none "${repo.repoUrl}" /app/repo
                    cd /app/repo
                    rgctl discover . --with-cfg --db /app/rgctl-db
                  `],
                  env: [{ name: "RGCTL_DB", value: "/app/rgctl-db" }],
                  volumeMounts: [
                    { name: "rgctl-db", mountPath: "/app/rgctl-db" },
                    { name: "tmp", mountPath: "/tmp" },
                    { name: "repo", mountPath: "/app/repo" },
                  ],
                  resources: { requests: { cpu: "500m", memory: "1Gi" }, limits: { cpu: "4", memory: "4Gi" } },
                }],
              },
            },
          },
        },
      },
    },
  }).catch((e) => { if (e.statusCode !== 409) throw e })
}
