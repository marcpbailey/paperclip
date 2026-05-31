import { randomUUID } from "node:crypto";
import { and, eq, sql } from "drizzle-orm";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import {
  activityLog,
  agents,
  agentRuntimeState,
  agentWakeupRequests,
  companySkills,
  companies,
  createDb,
  documentRevisions,
  documents,
  environmentLeases,
  environments,
  executionWorkspaces,
  heartbeatRunEvents,
  heartbeatRuns,
  issueComments,
  issueDocuments,
  issueRelations,
  issueTreeHolds,
  issues,
  workspaceOperations,
} from "@paperclipai/db";
import {
  getEmbeddedPostgresTestSupport,
  startEmbeddedPostgresTestDatabase,
} from "./helpers/embedded-postgres.js";
import { heartbeatService } from "../services/heartbeat.ts";
import { runningProcesses } from "../adapters/index.ts";

const mockAdapterExecute = vi.hoisted(() =>
  vi.fn(async () => ({
    exitCode: 0,
    signal: null,
    timedOut: false,
    errorMessage: null,
    summary: "becameInactive test run.",
    provider: "test",
    model: "test-model",
  })),
);

vi.mock("../adapters/index.ts", async () => {
  const actual = await vi.importActual<typeof import("../adapters/index.ts")>("../adapters/index.ts");
  return {
    ...actual,
    getServerAdapter: vi.fn(() => ({
      supportsLocalAgentJwt: false,
      execute: mockAdapterExecute,
    })),
  };
});

const embeddedPostgresSupport = await getEmbeddedPostgresTestSupport();
const describeEmbeddedPostgres = embeddedPostgresSupport.supported ? describe : describe.skip;

if (!embeddedPostgresSupport.supported) {
  console.warn(
    `Skipping embedded Postgres becameInactive wake tests on this host: ${embeddedPostgresSupport.reason ?? "unsupported environment"}`,
  );
}

async function ensureIssueRelationsTable(db: ReturnType<typeof createDb>) {
  await db.execute(sql.raw(`
    CREATE TABLE IF NOT EXISTS "issue_relations" (
      "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      "company_id" uuid NOT NULL,
      "issue_id" uuid NOT NULL,
      "related_issue_id" uuid NOT NULL,
      "type" text NOT NULL,
      "created_by_agent_id" uuid,
      "created_by_user_id" text,
      "created_at" timestamptz NOT NULL DEFAULT now(),
      "updated_at" timestamptz NOT NULL DEFAULT now()
    );
  `));
}

async function waitForCondition(fn: () => Promise<boolean>, timeoutMs = 5_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await fn()) return true;
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  return fn();
}

describeEmbeddedPostgres("heartbeat becameInactive wake", () => {
  let db!: ReturnType<typeof createDb>;
  let heartbeat!: ReturnType<typeof heartbeatService>;
  let tempDb: Awaited<ReturnType<typeof startEmbeddedPostgresTestDatabase>> | null = null;

  beforeAll(async () => {
    tempDb = await startEmbeddedPostgresTestDatabase("paperclip-heartbeat-became-inactive-");
    db = createDb(tempDb.connectionString);
    heartbeat = heartbeatService(db);
    await ensureIssueRelationsTable(db);
  }, 20_000);

  afterEach(async () => {
    mockAdapterExecute.mockReset();
    mockAdapterExecute.mockImplementation(async () => ({
      exitCode: 0,
      signal: null,
      timedOut: false,
      errorMessage: null,
      summary: "becameInactive test run.",
      provider: "test",
      model: "test-model",
    }));
    runningProcesses.clear();
    let idlePolls = 0;
    for (let attempt = 0; attempt < 100; attempt += 1) {
      const runs = await db
        .select({ status: heartbeatRuns.status })
        .from(heartbeatRuns);
      const hasActiveRun = runs.some((run) => run.status === "queued" || run.status === "running");
      if (!hasActiveRun) {
        idlePolls += 1;
        if (idlePolls >= 3) break;
      } else {
        idlePolls = 0;
      }
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    await new Promise((resolve) => setTimeout(resolve, 50));
    await db.delete(environmentLeases);
    await db.delete(activityLog);
    await db.delete(companySkills);
    await db.delete(issueComments);
    await db.delete(issueDocuments);
    await db.delete(documentRevisions);
    await db.delete(documents);
    await db.delete(issueRelations);
    await db.delete(issueTreeHolds);
    await db.delete(issues);
    await db.delete(heartbeatRunEvents);
    await db.delete(activityLog);
    await db.delete(heartbeatRuns);
    await db.delete(agentWakeupRequests);
    await db.delete(agentRuntimeState);
    await db.delete(agents);
    await db.delete(companySkills);
    await db.delete(environments);
    await db.delete(workspaceOperations);
    await db.delete(executionWorkspaces);
    await db.delete(companies);
  });

  afterAll(async () => {
    await tempDb?.cleanup();
  });

  it("fires issue_blockers_resolved wake when blocked issue has no unresolved blockers at lease release", async () => {
    // Reproduces the race from LINAA-884:
    // 1. Parent run starts executing.
    // 2. Mid-run: agent creates child probe, inserts blocker relation, sets parent → blocked.
    // 3. Child completes (done) before parent's run releases its lease.
    // 4. issue_blockers_resolved was missed (lease held).
    // 5. On lease release, becameInactive check should fire a re-wake.

    const companyId = randomUUID();
    const agentId = randomUUID();
    const parentIssueId = randomUUID();
    const childIssueId = randomUUID();

    let finishParentRun!: () => void;
    const parentRunCanFinish = new Promise<void>((resolve) => {
      finishParentRun = resolve;
    });

    mockAdapterExecute.mockImplementationOnce(async () => {
      await parentRunCanFinish;
      return {
        exitCode: 0,
        signal: null,
        timedOut: false,
        errorMessage: null,
        summary: "becameInactive parent run.",
        provider: "test",
        model: "test-model",
      };
    });

    await db.insert(companies).values({
      id: companyId,
      name: "BecameInactiveCo",
      issuePrefix: `BI${companyId.replace(/-/g, "").slice(0, 6).toUpperCase()}`,
      requireBoardApprovalForNewAgents: false,
    });
    await db.insert(agents).values({
      id: agentId,
      companyId,
      name: "Natasha",
      role: "engineer",
      status: "active",
      adapterType: "codex_local",
      adapterConfig: {},
      runtimeConfig: {
        heartbeat: {
          wakeOnDemand: true,
          maxConcurrentRuns: 1,
        },
      },
      permissions: {},
    });
    // Parent starts in todo with no blockers — wakeup proceeds immediately.
    await db.insert(issues).values([
      {
        id: parentIssueId,
        companyId,
        title: "Parent task",
        status: "todo",
        priority: "high",
        assigneeAgentId: agentId,
      },
      {
        id: childIssueId,
        companyId,
        title: "Child probe",
        status: "todo",
        priority: "high",
      },
    ]);

    // Start the parent run.
    const parentWake = await heartbeat.wakeup(agentId, {
      source: "assignment",
      triggerDetail: "system",
      reason: "issue_assigned",
      payload: { issueId: parentIssueId },
      contextSnapshot: { issueId: parentIssueId, wakeReason: "issue_assigned" },
    });
    expect(parentWake).not.toBeNull();

    // Wait for the adapter to be executing (run is running).
    const runStarted = await waitForCondition(
      async () => mockAdapterExecute.mock.calls.length === 1,
    );
    expect(runStarted).toBe(true);

    // Mid-run: simulate agent creating child probe, adding blocker relation,
    // setting parent to blocked. Child completes immediately.
    await db.insert(issueRelations).values({
      companyId,
      issueId: childIssueId,
      relatedIssueId: parentIssueId,
      type: "blocks",
    });
    await db.update(issues).set({ status: "done", updatedAt: new Date() }).where(eq(issues.id, childIssueId));
    await db.update(issues).set({ status: "blocked", updatedAt: new Date() }).where(eq(issues.id, parentIssueId));

    // Let the parent run finish — this releases the lease and triggers becameInactive.
    finishParentRun();

    const parentRunSucceeded = await waitForCondition(async () => {
      const run = await db
        .select({ status: heartbeatRuns.status })
        .from(heartbeatRuns)
        .where(eq(heartbeatRuns.id, parentWake!.id))
        .then((rows) => rows[0] ?? null);
      return run?.status === "succeeded";
    });
    expect(parentRunSucceeded).toBe(true);

    // becameInactive should have enqueued a second wakeup for the parent
    // with reason "issue_blockers_resolved" and deferredFor "became_inactive".
    const becameInactiveWakeQueued = await waitForCondition(async () => {
      const wake = await db
        .select({
          reason: agentWakeupRequests.reason,
          payload: agentWakeupRequests.payload,
        })
        .from(agentWakeupRequests)
        .where(
          and(
            eq(agentWakeupRequests.agentId, agentId),
            eq(agentWakeupRequests.reason, "issue_blockers_resolved"),
            sql`${agentWakeupRequests.payload} ->> 'issueId' = ${parentIssueId}`,
            sql`${agentWakeupRequests.payload} ->> 'deferredFor' = 'became_inactive'`,
          ),
        )
        .then((rows) => rows[0] ?? null);
      return Boolean(wake);
    });
    expect(becameInactiveWakeQueued).toBe(true);

    // A second run should have been started for the parent.
    const secondRunStarted = await waitForCondition(async () => {
      const count = await db
        .select({ count: sql<number>`count(*)::int` })
        .from(heartbeatRuns)
        .where(
          and(
            eq(heartbeatRuns.agentId, agentId),
            sql`${heartbeatRuns.contextSnapshot} ->> 'issueId' = ${parentIssueId}`,
          ),
        )
        .then((rows) => rows[0]?.count ?? 0);
      return count >= 2;
    });
    expect(secondRunStarted).toBe(true);

    // Drain the cascade: mark parent done so subsequent becameInactive checks
    // skip it (the mock adapter never transitions it, which would loop forever).
    await db.update(issues).set({ status: "done", updatedAt: new Date() }).where(eq(issues.id, parentIssueId));
  }, 20_000);

  it("does not fire a spurious wake when the run's issue is not blocked at lease release", async () => {
    const companyId = randomUUID();
    const agentId = randomUUID();
    const issueId = randomUUID();

    await db.insert(companies).values({
      id: companyId,
      name: "BecameInactiveCo2",
      issuePrefix: `BI${companyId.replace(/-/g, "").slice(0, 6).toUpperCase()}`,
      requireBoardApprovalForNewAgents: false,
    });
    await db.insert(agents).values({
      id: agentId,
      companyId,
      name: "Natasha",
      role: "engineer",
      status: "active",
      adapterType: "codex_local",
      adapterConfig: {},
      runtimeConfig: {
        heartbeat: {
          wakeOnDemand: true,
          maxConcurrentRuns: 1,
        },
      },
      permissions: {},
    });
    await db.insert(issues).values({
      id: issueId,
      companyId,
      title: "Normal task",
      status: "todo",
      priority: "high",
      assigneeAgentId: agentId,
    });

    const wake = await heartbeat.wakeup(agentId, {
      source: "assignment",
      triggerDetail: "system",
      reason: "issue_assigned",
      payload: { issueId },
      contextSnapshot: { issueId, wakeReason: "issue_assigned" },
    });
    expect(wake).not.toBeNull();

    const runSucceeded = await waitForCondition(async () => {
      const run = await db
        .select({ status: heartbeatRuns.status })
        .from(heartbeatRuns)
        .where(eq(heartbeatRuns.id, wake!.id))
        .then((rows) => rows[0] ?? null);
      return run?.status === "succeeded";
    });
    expect(runSucceeded).toBe(true);

    // Wait briefly to ensure no becameInactive wake is fired.
    await new Promise((resolve) => setTimeout(resolve, 200));

    // The issue was never blocked, so no becameInactive wake should fire.
    const becameInactiveWakes = await db
      .select()
      .from(agentWakeupRequests)
      .where(
        and(
          eq(agentWakeupRequests.agentId, agentId),
          sql`${agentWakeupRequests.payload} ->> 'deferredFor' = 'became_inactive'`,
        ),
      );
    expect(becameInactiveWakes).toHaveLength(0);
  }, 20_000);

  it("does not fire a wake when the issue is blocked but still has unresolved blockers", async () => {
    const companyId = randomUUID();
    const agentId = randomUUID();
    const parentIssueId = randomUUID();
    const resolvedBlockerId = randomUUID();
    const unresolvedBlockerId = randomUUID();

    let finishRun!: () => void;
    const runCanFinish = new Promise<void>((resolve) => {
      finishRun = resolve;
    });

    mockAdapterExecute.mockImplementationOnce(async () => {
      await runCanFinish;
      return {
        exitCode: 0,
        signal: null,
        timedOut: false,
        errorMessage: null,
        summary: "unresolved blockers run.",
        provider: "test",
        model: "test-model",
      };
    });

    await db.insert(companies).values({
      id: companyId,
      name: "BecameInactiveCo3",
      issuePrefix: `BI${companyId.replace(/-/g, "").slice(0, 6).toUpperCase()}`,
      requireBoardApprovalForNewAgents: false,
    });
    await db.insert(agents).values({
      id: agentId,
      companyId,
      name: "Natasha",
      role: "engineer",
      status: "active",
      adapterType: "codex_local",
      adapterConfig: {},
      runtimeConfig: {
        heartbeat: {
          wakeOnDemand: true,
          maxConcurrentRuns: 1,
        },
      },
      permissions: {},
    });
    // Parent starts in todo, no blockers yet.
    await db.insert(issues).values([
      {
        id: parentIssueId,
        companyId,
        title: "Parent task",
        status: "todo",
        priority: "high",
        assigneeAgentId: agentId,
      },
      {
        id: resolvedBlockerId,
        companyId,
        title: "Resolved blocker",
        status: "todo",
        priority: "high",
      },
      {
        id: unresolvedBlockerId,
        companyId,
        title: "Unresolved blocker",
        status: "todo",
        priority: "high",
      },
    ]);

    const parentWake = await heartbeat.wakeup(agentId, {
      source: "assignment",
      triggerDetail: "system",
      reason: "issue_assigned",
      payload: { issueId: parentIssueId },
      contextSnapshot: { issueId: parentIssueId, wakeReason: "issue_assigned" },
    });
    expect(parentWake).not.toBeNull();

    const runStarted = await waitForCondition(
      async () => mockAdapterExecute.mock.calls.length === 1,
    );
    expect(runStarted).toBe(true);

    // Mid-run: two blockers added, only one resolves.
    await db.insert(issueRelations).values([
      {
        companyId,
        issueId: resolvedBlockerId,
        relatedIssueId: parentIssueId,
        type: "blocks",
      },
      {
        companyId,
        issueId: unresolvedBlockerId,
        relatedIssueId: parentIssueId,
        type: "blocks",
      },
    ]);
    await db.update(issues).set({ status: "done", updatedAt: new Date() }).where(eq(issues.id, resolvedBlockerId));
    await db.update(issues).set({ status: "blocked", updatedAt: new Date() }).where(eq(issues.id, parentIssueId));
    // unresolvedBlockerId stays in its current status — still an unresolved blocker.

    finishRun();

    const runSucceeded = await waitForCondition(async () => {
      const run = await db
        .select({ status: heartbeatRuns.status })
        .from(heartbeatRuns)
        .where(eq(heartbeatRuns.id, parentWake!.id))
        .then((rows) => rows[0] ?? null);
      return run?.status === "succeeded";
    });
    expect(runSucceeded).toBe(true);

    // Wait briefly — no becameInactive wake should fire since there's still one unresolved blocker.
    await new Promise((resolve) => setTimeout(resolve, 200));

    const becameInactiveWakes = await db
      .select()
      .from(agentWakeupRequests)
      .where(
        and(
          eq(agentWakeupRequests.agentId, agentId),
          sql`${agentWakeupRequests.payload} ->> 'deferredFor' = 'became_inactive'`,
        ),
      );
    expect(becameInactiveWakes).toHaveLength(0);

    const runCount = await db
      .select({ count: sql<number>`count(*)::int` })
      .from(heartbeatRuns)
      .where(eq(heartbeatRuns.agentId, agentId))
      .then((rows) => rows[0]?.count ?? 0);
    expect(runCount).toBe(1);
  }, 20_000);
});
