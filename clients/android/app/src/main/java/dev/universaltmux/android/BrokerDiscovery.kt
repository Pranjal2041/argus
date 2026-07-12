package dev.universaltmux.android

/** Whether a broker is pinned by the user or maintained by tailnet discovery. */
enum class BrokerSource { MANUAL, DISCOVERED }

/** A discovery answer is authoritative only when the embedded tailnet node
 * successfully read peer status. An empty authoritative answer means no broker
 * is currently online; an empty non-authoritative answer means "do not prune". */
data class BrokerDiscovery(
    val brokers: List<Broker>,
    val authoritative: Boolean,
)

data class BrokerReconcileResult(
    val brokers: List<Broker>,
    val sources: Map<String, BrokerSource>,
    val misses: Map<String, Int>,
    val removed: List<Broker>,
)

/** Pure discovery reducer, kept outside AppViewModel so stale-node behavior has
 * deterministic JVM regression tests. Automatic sweeps require several
 * consecutive misses; a user refresh can request an immediate authoritative
 * prune, matching the macOS refresh behavior. */
object BrokerDiscoveryPolicy {
    const val AUTO_PRUNE_MISSES = 3

    fun key(host: String): String = host.trim().trimEnd('.').lowercase()

    /** Before source metadata existed, embedded discovery saved tailnet DNS
     * names while hand-entered LAN/IP hosts were normally not *.ts.net. This
     * migration preserves those likely-manual endpoints and lets legacy
     * tailnet nodes finally age out. */
    fun legacySource(host: String): BrokerSource =
        if (key(host).endsWith(".ts.net")) BrokerSource.DISCOVERED else BrokerSource.MANUAL

    fun reconcile(
        current: List<Broker>,
        discovered: List<Broker>,
        sources: Map<String, BrokerSource>,
        misses: Map<String, Int>,
        authoritative: Boolean,
        pruneNow: Boolean = false,
        missLimit: Int = AUTO_PRUNE_MISSES,
    ): BrokerReconcileResult {
        val found = linkedMapOf<String, Broker>()
        discovered.sortedWith(compareBy({ it.name.lowercase() }, { key(it.host) })).forEach {
            found[key(it.host)] = it
        }
        val next = current.map { saved ->
            found[key(saved.host)]?.let { incoming -> incoming.copy(host = saved.host) } ?: saved
        }.toMutableList()
        val nextSources = sources.toMutableMap()
        val nextMisses = misses.toMutableMap()

        found.forEach { (brokerKey, broker) ->
            if (next.none { key(it.host) == brokerKey }) next += broker
            nextSources.putIfAbsent(brokerKey, BrokerSource.DISCOVERED)
            nextMisses.remove(brokerKey)
        }

        val removed = mutableListOf<Broker>()
        if (authoritative) {
            current.forEach { broker ->
                val brokerKey = key(broker.host)
                if (brokerKey in found || nextSources[brokerKey] == BrokerSource.MANUAL) return@forEach
                val count = if (pruneNow) missLimit else (nextMisses[brokerKey] ?: 0) + 1
                if (count >= missLimit) {
                    next.removeAll { key(it.host) == brokerKey }
                    nextSources.remove(brokerKey)
                    nextMisses.remove(brokerKey)
                    removed += broker
                } else {
                    nextMisses[brokerKey] = count
                }
            }
        }

        val live = next.mapTo(hashSetOf()) { key(it.host) }
        nextSources.keys.retainAll(live)
        nextMisses.keys.retainAll(live)
        return BrokerReconcileResult(next, nextSources, nextMisses, removed)
    }
}
