package dev.universaltmux.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BrokerDiscoveryPolicyTest {
    @Test
    fun autoDiscoveredBrokerAgesOutAfterConsecutiveAuthoritativeMisses() {
        val stale = broker("stale.tailnet.ts.net", "stale")
        var state = BrokerReconcileResult(
            brokers = listOf(stale),
            sources = mapOf(BrokerDiscoveryPolicy.key(stale.host) to BrokerSource.DISCOVERED),
            misses = emptyMap(),
            removed = emptyList(),
        )

        repeat(BrokerDiscoveryPolicy.AUTO_PRUNE_MISSES - 1) {
            state = reconcile(state, authoritative = true)
            assertEquals(listOf(stale), state.brokers)
            assertTrue(state.removed.isEmpty())
        }
        state = reconcile(state, authoritative = true)

        assertTrue(state.brokers.isEmpty())
        assertEquals(listOf(stale), state.removed)
    }

    @Test
    fun transientDiscoveryFailureNeverAdvancesMissCounter() {
        val stale = broker("stale.tailnet.ts.net", "stale")
        val state = BrokerReconcileResult(
            listOf(stale),
            mapOf(BrokerDiscoveryPolicy.key(stale.host) to BrokerSource.DISCOVERED),
            mapOf(BrokerDiscoveryPolicy.key(stale.host) to 1),
            emptyList(),
        )

        val next = reconcile(state, authoritative = false)

        assertEquals(state.brokers, next.brokers)
        assertEquals(state.misses, next.misses)
        assertTrue(next.removed.isEmpty())
    }

    @Test
    fun manualBrokerIsPinnedEvenDuringImmediatePrune() {
        val manual = broker("192.168.0.50", "manual")
        val state = BrokerReconcileResult(
            listOf(manual),
            mapOf(BrokerDiscoveryPolicy.key(manual.host) to BrokerSource.MANUAL),
            emptyMap(),
            emptyList(),
        )

        val next = reconcile(state, authoritative = true, pruneNow = true)

        assertEquals(listOf(manual), next.brokers)
        assertTrue(next.removed.isEmpty())
    }

    @Test
    fun userRefreshPrunesMissingDiscoveredBrokerImmediately() {
        val stale = broker("stale.tailnet.ts.net", "stale")
        val state = BrokerReconcileResult(
            listOf(stale),
            mapOf(BrokerDiscoveryPolicy.key(stale.host) to BrokerSource.DISCOVERED),
            emptyMap(),
            emptyList(),
        )

        val next = reconcile(state, authoritative = true, pruneNow = true)

        assertTrue(next.brokers.isEmpty())
        assertEquals(listOf(stale), next.removed)
    }

    @Test
    fun discoveryRefreshesMetadataWithoutChangingStableHostIdentity() {
        val saved = Broker("Node.Tailnet.TS.Net", "http", "old")
        val live = Broker("node.tailnet.ts.net", "https", "new", "linux")
        val state = BrokerReconcileResult(
            listOf(saved),
            mapOf(BrokerDiscoveryPolicy.key(saved.host) to BrokerSource.DISCOVERED),
            mapOf(BrokerDiscoveryPolicy.key(saved.host) to 2),
            emptyList(),
        )

        val next = BrokerDiscoveryPolicy.reconcile(
            state.brokers, listOf(live), state.sources, state.misses, authoritative = true,
        )

        assertEquals(saved.host, next.brokers.single().host)
        assertEquals("new", next.brokers.single().name)
        assertEquals("https", next.brokers.single().scheme)
        assertTrue(next.misses.isEmpty())
    }

    @Test
    fun legacyMigrationPreservesLanHostsButManagesTailnetDns() {
        assertEquals(BrokerSource.MANUAL, BrokerDiscoveryPolicy.legacySource("192.168.0.10"))
        assertEquals(BrokerSource.MANUAL, BrokerDiscoveryPolicy.legacySource("desktop.local"))
        assertEquals(BrokerSource.DISCOVERED, BrokerDiscoveryPolicy.legacySource("ut-node.example.ts.net"))
    }

    @Test
    fun discoveryEnvelopeMakesRealEmptyResultAuthoritative() {
        val current = TsnetCore.parseDiscovery("{\"ok\":true,\"brokers\":[]}")
        val failed = TsnetCore.parseDiscovery("{\"ok\":false,\"brokers\":[]}")
        val legacyEmpty = TsnetCore.parseDiscovery("[]")
        val legacyFound = TsnetCore.parseDiscovery(
            "[{\"host\":\"node.ts.net\",\"scheme\":\"https\",\"name\":\"node\"}]",
        )

        assertTrue(current.authoritative)
        assertFalse(failed.authoritative)
        assertFalse(legacyEmpty.authoritative)
        assertTrue(legacyFound.authoritative)
        assertEquals("node", legacyFound.brokers.single().name)
    }

    private fun reconcile(
        state: BrokerReconcileResult,
        authoritative: Boolean,
        pruneNow: Boolean = false,
    ) = BrokerDiscoveryPolicy.reconcile(
        state.brokers,
        emptyList(),
        state.sources,
        state.misses,
        authoritative,
        pruneNow,
    )

    private fun broker(host: String, name: String) = Broker(host, "https", name)
}
