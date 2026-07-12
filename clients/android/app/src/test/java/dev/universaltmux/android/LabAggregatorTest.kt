package dev.universaltmux.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class LabAggregatorTest {
    @Test
    fun sharedBabelStoreProducesOneCopyAndRoutesToOwner() {
        val n5 = broker("babel-n5-24")
        val u5 = broker("babel-u5-24")
        val brief = brief("s-93k08z", "babel-n5-24")
        val pending = LabKeyInfo(
            key = "pending-key", project = "vlm_gating", machine = "babel-n5-24",
            cwd = "/shared/vlm_gating", session = "vlm_gating", status = "pending",
            created = "2026-07-11T16:00:00Z",
        )
        val active = pending.copy(
            key = "active-key", set = "s-93k08z", status = "active",
            created = "2026-07-11T15:00:00Z",
        )
        val proposal = LabProposal(
            set = "s-93k08z", run = "R3", project = "vlm_gating",
            machine = "babel-n5-24", intent = "compare router loss", tier = "full",
            group = "ablation", argv = listOf("python", "train.py"),
            cwd = "/shared/vlm_gating", created = "2026-07-11T17:00:00Z",
        )
        val global = LabHubNote(
            scope = "global", id = "global-1", time = "2026-07-10T00:00:00Z",
            author = "human", text = "show the full parameters",
        )
        val snapshots = listOf(
            LabBrokerSnapshot(n5, "one-nfs-store", listOf(brief), listOf(pending, active), listOf(proposal), listOf(global)),
            LabBrokerSnapshot(u5, "one-nfs-store", listOf(brief), listOf(pending, active), listOf(proposal), listOf(global)),
        )

        val result = LabAggregator.aggregate(snapshots)

        assertEquals(1, result.sets.size)
        assertEquals(1, result.pendingKeys.size)
        assertEquals(1, result.pendingRuns.size)
        assertEquals(2, result.notes.size) // machine guidance remains addressable per node
        assertEquals(n5.id, result.sets.single().broker.id)
        assertEquals(n5.id, result.pendingKeys.single().broker.id)
        assertEquals(n5.id, result.pendingRuns.single().broker.id)
        assertEquals("shared:babel", result.sets.single().storeID)
        assertEquals("active-key", result.activeKeyBySet[result.sets.single().id])
        assertEquals(listOf(LabAttentionKind.PROPOSAL, LabAttentionKind.KEY), result.attention.map { it.kind })
        assertEquals("compare router loss", result.attention.first().summary)
    }

    @Test
    fun sameRecordOnIndependentStoresRemainsIndependent() {
        val alpha = broker("alpha")
        val beta = broker("beta")
        val result = LabAggregator.aggregate(listOf(
            LabBrokerSnapshot(alpha, "store-a", listOf(brief("s-same", "alpha")), emptyList(), emptyList(), emptyList()),
            LabBrokerSnapshot(beta, "store-b", listOf(brief("s-same", "beta")), emptyList(), emptyList(), emptyList()),
        ))

        assertEquals(2, result.sets.size)
        assertEquals(setOf("store:store-a", "store:store-b"), result.sets.map { it.storeID }.toSet())
    }

    @Test
    fun reportedSharedStoreDeduplicatesNonBabelPeers() {
        val alpha = broker("alpha")
        val beta = broker("beta")
        val shared = brief("s-shared", "beta")
        val result = LabAggregator.aggregate(listOf(
            LabBrokerSnapshot(alpha, "cluster-store", listOf(shared), emptyList(), emptyList(), emptyList()),
            LabBrokerSnapshot(beta, "cluster-store", listOf(shared), emptyList(), emptyList(), emptyList()),
        ))

        assertEquals(1, result.sets.size)
        assertEquals("store:cluster-store", result.sets.single().storeID)
        assertEquals(beta.id, result.sets.single().broker.id)
    }

    @Test
    fun babelPrefixDeduplicatesWhenStoreIdentityIsUnavailable() {
        val brief = brief("s-shared", "babel-n5-24")
        val result = LabAggregator.aggregate(listOf(
            LabBrokerSnapshot(broker("babel-n5-24"), null, listOf(brief), emptyList(), emptyList(), null),
            LabBrokerSnapshot(broker("babel-u5-24"), null, listOf(brief), emptyList(), emptyList(), null),
        ))

        assertEquals(1, result.sets.size)
        assertEquals("shared:babel", result.sets.single().storeID)
    }

    @Test
    fun newestResultActivityOrdersSetsAheadOfNewerCreatedButStaleSets() {
        val alpha = broker("alpha")
        val stale = brief("s-stale", "alpha").copy(
            set = brief("s-stale", "alpha").set.copy(created = "2026-07-12T12:00:00Z"),
            runs = listOf(LabRunSummary(id = "R1", status = "done", started = "2026-07-12T12:10:00Z",
                latest = "old", latestAt = "2026-07-12T12:20:00Z")),
        )
        val updated = brief("s-updated", "alpha").copy(
            set = brief("s-updated", "alpha").set.copy(created = "2026-07-11T12:00:00Z"),
            runs = listOf(LabRunSummary(id = "R1", status = "done", started = "2026-07-11T12:10:00Z",
                latest = "fresh", latestAt = "2026-07-12T13:00:00Z")),
        )

        val result = LabAggregator.aggregate(listOf(
            LabBrokerSnapshot(alpha, "alpha-store", listOf(stale, updated), emptyList(), emptyList(), emptyList()),
        ))

        assertEquals(listOf("s-updated", "s-stale"), result.sets.map { it.brief.set.id })
    }

    @Test
    fun newestOfflineMirrorWinsAndOnlineOwnerSuppressesMirror() {
        val mac = Broker("mac.example.ts.net", "https", "this mac", "darwin")
        val old = LabMirrored("alpha", "s-one", "2026-07-10T00:00:00Z", brief("s-one", "alpha"))
        val fresh = old.copy(updated = "2026-07-11T00:00:00Z")

        val offline = LabAggregator.aggregate(emptyList(), listOf(old, fresh), mac)
        assertEquals(1, offline.sets.size)
        assertTrue(offline.sets.single().offline)
        assertEquals(fresh.updated, offline.sets.single().mirroredAt)

        val alpha = broker("alpha")
        val online = LabAggregator.aggregate(
            listOf(LabBrokerSnapshot(alpha, "alpha-store", listOf(brief("s-one", "alpha")), emptyList(), emptyList(), emptyList())),
            listOf(fresh),
            mac,
        )
        assertEquals(1, online.sets.size)
        assertTrue(!online.sets.single().offline)
    }

    private fun broker(name: String) = Broker(
        host = "ut-$name.example.ts.net", scheme = "https", name = name,
    )

    private fun brief(set: String, machine: String) = LabBrief(
        set = LabSetMeta(
            id = set, project = "vlm_gating", machine = machine,
            cwd = "/shared/vlm_gating", created = "2026-07-11T15:00:00Z",
        ),
        runs = listOf(LabRunSummary(
            id = "R2", group = "ablation", tier = "full", status = "running",
            started = "2026-07-11T16:00:00Z", latest = "healthy",
        )),
    )
}
