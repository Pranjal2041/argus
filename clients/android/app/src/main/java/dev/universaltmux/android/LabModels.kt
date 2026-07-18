package dev.universaltmux.android

const val SCREEN_LAB = 7

/** Wire and presentation models for Argus Lab. The Android client deliberately
 * owns these instead of leaking JSONObject into Compose or AppViewModel state. */
data class LabSetMeta(
    val id: String,
    val project: String,
    val machine: String,
    val store: String? = null,
    val cwd: String,
    val created: String,
)

data class LabFileRef(val path: String, val sha256: String? = null)

data class LabSnapshotInfo(
    val baseSha: String? = null,
    val noGit: Boolean = false,
    val patchBytes: Long = 0,
    val archived: Int = 0,
)

data class LabEnvFacts(
    val os: String? = null,
    val arch: String? = null,
    val python: String? = null,
    val gpus: String? = null,
)

data class LabEventData(
    val target: String? = null,
    val machine: String? = null,
    val argv: List<String> = emptyList(),
    val cwd: String? = null,
    val tier: String? = null,
    val group: String? = null,
    val tmuxSession: String? = null,
    val bind: String? = null,
    val snapshot: LabSnapshotInfo? = null,
    val params: List<LabFileRef> = emptyList(),
    val dataFiles: List<LabFileRef> = emptyList(),
    val env: LabEnvFacts? = null,
    val exitCode: Int? = null,
    val durationSec: Int? = null,
    val wandb: List<String> = emptyList(),
    val drift: List<String> = emptyList(),
)

data class LabEvent(
    val id: String,
    val time: String,
    val author: String,
    val kind: String,
    val text: String? = null,
    val data: LabEventData? = null,
)

data class LabRunSummary(
    val id: String,
    val machine: String? = null,
    val group: String? = null,
    val tier: String? = null,
    val status: String,
    val started: String? = null,
    val stoppedAt: String? = null,
    val stopReason: String? = null,
    val latest: String? = null,
    val latestAt: String? = null,
    val exitCode: Int = -1,
    val archived: Boolean = false,
)

data class LabBrief(
    val set: LabSetMeta,
    val policy: String = "full-only",
    val notes: List<LabEvent> = emptyList(),
    val setEvents: List<LabEvent> = emptyList(),
    val runs: List<LabRunSummary> = emptyList(),
    val archived: Boolean = false,
)

data class LabKeyInfo(
    val key: String,
    val set: String? = null,
    val project: String,
    val machine: String,
    val store: String? = null,
    val cwd: String,
    val session: String? = null,
    val status: String,
    val created: String,
)

data class LabProposal(
    val set: String,
    val run: String,
    val project: String,
    val machine: String,
    val intent: String,
    val tier: String? = null,
    val group: String? = null,
    val argv: List<String> = emptyList(),
    val cwd: String? = null,
    val created: String,
) {
    val id get() = "$set/$run"
}

data class LabHubNote(
    val scope: String,
    val project: String? = null,
    val id: String,
    val time: String,
    val author: String,
    val text: String,
    val hidden: Boolean = false,
)

data class LabRunFileInfo(val name: String, val size: Long)

data class LabMirrored(
    val machine: String,
    val set: String,
    val updated: String,
    val brief: LabBrief,
)

/** One reachable broker's complete Lab answer. [notes] is null only when the
 * identity endpoint was unreachable; an empty note list is a valid answer. */
data class LabBrokerSnapshot(
    val broker: Broker,
    val reportedStoreID: String?,
    val briefs: List<LabBrief>,
    val keys: List<LabKeyInfo>,
    val proposals: List<LabProposal>,
    val notes: List<LabHubNote>?,
)

data class LabSetCard(
    val storeID: String,
    val broker: Broker,
    val machineName: String,
    val brief: LabBrief,
    val offline: Boolean = false,
    val mirroredAt: String = "",
) {
    val id get() = "${broker.id}/${brief.set.id}"
}

data class LabPendingKey(
    val storeID: String,
    val broker: Broker,
    val machineName: String,
    val key: LabKeyInfo,
) {
    val id get() = "${broker.id}/${key.key}"
}

data class LabPendingRun(
    val storeID: String,
    val broker: Broker,
    val machineName: String,
    val proposal: LabProposal,
) {
    val id get() = "${broker.id}/${proposal.id}"
}

data class LabNotesGroup(
    val storeID: String,
    val broker: Broker,
    val machineName: String,
    val notes: List<LabHubNote>,
) {
    val id get() = broker.id
}

enum class LabAttentionKind { KEY, PROPOSAL }

data class LabAttentionItem(
    val kind: LabAttentionKind,
    val targetID: String,
    val reference: String,
    val project: String,
    val machineName: String,
    val summary: String,
    val created: String,
) {
    val id get() = "${kind.name.lowercase()}/$targetID"
}

data class LabAggregate(
    val sets: List<LabSetCard>,
    val pendingKeys: List<LabPendingKey>,
    val pendingRuns: List<LabPendingRun>,
    val notes: List<LabNotesGroup>,
    val activeKeyBySet: Map<String, String>,
    val attention: List<LabAttentionItem>,
)

data class LabRunDetail(
    val events: List<LabEvent> = emptyList(),
    val files: List<LabRunFileInfo> = emptyList(),
    val textByName: Map<String, String> = emptyMap(),
) {
    val envelope: LabEventData?
        get() = events.firstOrNull { it.kind == "run-start" }?.data
            ?: events.firstOrNull { it.kind == "proposal" }?.data
    val end: LabEventData? get() = events.lastOrNull { it.kind == "run-end" }?.data
}

internal fun labRunActivityAt(run: LabRunSummary, fallback: String = ""): String =
    listOfNotNull(run.latestAt, run.stoppedAt, run.started, fallback.takeIf(String::isNotEmpty)).maxOrNull().orEmpty()

/** Lifecycle phase is independent from the archive view flag. */
internal fun labRunPhase(run: LabRunSummary): String {
    val status = run.status.lowercase()
    return when {
        "awaiting approval" in status || status.startsWith("proposed") -> "needs"
        status.startsWith("approved") -> "approved"
        status.startsWith("running") -> "running"
        status.startsWith("failed") -> "failed"
        status.startsWith("stopped") -> "stopped"
        status.startsWith("denied") -> "rejected"
        status.startsWith("done") -> "finished"
        else -> "recorded"
    }
}

internal fun labCardActivityAt(card: LabSetCard): String =
    card.brief.runs.maxOfOrNull { labRunActivityAt(it, card.brief.set.created) } ?: card.brief.set.created

enum class LabArea { INBOX, RESEARCH, GUIDANCE }

/** Navigation is state owned by the view model so notification and Command
 * Center taps can land on an exact native Lab destination. */
data class LabRoute(
    val area: LabArea = LabArea.INBOX,
    val attentionKind: LabAttentionKind? = null,
    val targetID: String = "",
    val cardID: String = "",
    val runID: String = "",
    val compareRunA: String = "",
    val compareRunB: String = "",
    val guidanceKey: String = "all",
)

/** Shared-store reduction used by both production state and JVM regression
 * tests. Sets, keys, and proposals belong to a Lab store—not to each broker
 * that happens to expose that store. */
object LabAggregator {
    fun aggregate(
        snapshots: List<LabBrokerSnapshot>,
        mirrored: List<LabMirrored> = emptyList(),
        mirrorBroker: Broker? = null,
    ): LabAggregate {
        val groups = snapshots.sortedWith(compareBy({ it.broker.name.lowercase() }, { it.broker.id }))
            .groupBy { storeKey(it.broker, it.reportedStoreID) }
        val cards = linkedMapOf<String, LabSetCard>()
        val pendingKeys = linkedMapOf<String, LabPendingKey>()
        val pendingRuns = linkedMapOf<String, LabPendingRun>()
        val activeKeys = linkedMapOf<String, LabKeyInfo>()
        val noteGroups = mutableListOf<LabNotesGroup>()

        groups.toSortedMap().forEach { (storeID, peers) ->
            if (peers.isEmpty()) return@forEach
            val fallback = peers.first()
            val briefs = linkedMapOf<String, LabBrief>()
            val keys = linkedMapOf<String, LabKeyInfo>()
            val proposals = linkedMapOf<String, LabProposal>()
            peers.forEach { peer ->
                peer.briefs.forEach { candidate ->
                    val current = briefs[candidate.set.id]
                    if (current == null || prefer(candidate, current)) briefs[candidate.set.id] = candidate
                }
                peer.keys.forEach { candidate ->
                    val current = keys[candidate.key]
                    if (current == null || keyRank(candidate.status) > keyRank(current.status)) keys[candidate.key] = candidate
                }
                peer.proposals.forEach { proposals.putIfAbsent(it.id, it) }
                peer.notes?.let {
                    noteGroups += LabNotesGroup(storeID, peer.broker, peer.broker.name, it)
                }
            }

            briefs.values.forEach { brief ->
                val route = peers.firstOrNull { machineMatches(it.broker, brief.set.machine) } ?: fallback
                cards["$storeID/set/${brief.set.id}"] = LabSetCard(
                    storeID, route.broker, route.broker.name, brief,
                )
            }
            keys.values.forEach { key ->
                val route = peers.firstOrNull { machineMatches(it.broker, key.machine) } ?: fallback
                when {
                    key.status == "pending" -> pendingKeys["$storeID/key/${key.key}"] =
                        LabPendingKey(storeID, route.broker, route.broker.name, key)
                    key.status == "active" && key.set != null -> activeKeys["$storeID/set/${key.set}"] = key
                }
            }
            proposals.values.forEach { proposal ->
                val route = peers.firstOrNull { machineMatches(it.broker, proposal.machine) } ?: fallback
                pendingRuns["$storeID/proposal/${proposal.id}"] =
                    LabPendingRun(storeID, route.broker, route.broker.name, proposal)
            }
        }

        // A Mac mirror may itself contain the same NFS-backed set under more
        // than one peer directory. Embedded home machine + set id is durable.
        val onlineOwners = cards.values.mapTo(hashSetOf()) { normalizeMachine(it.brief.set.machine) }
        val mirrorByRecord = linkedMapOf<String, LabMirrored>()
        mirrored.forEach { item ->
            val owner = item.brief.set.machine.ifEmpty { item.machine }
            if (normalizeMachine(owner) in onlineOwners) return@forEach
            val record = "${normalizeMachine(owner)}/set/${item.brief.set.id}"
            val current = mirrorByRecord[record]
            if (current == null || item.updated > current.updated) mirrorByRecord[record] = item
        }
        if (mirrorBroker != null) mirrorByRecord.values.forEach { item ->
            val owner = item.brief.set.machine.ifEmpty { item.machine }
            cards["mirror/${normalizeMachine(owner)}/set/${item.brief.set.id}"] = LabSetCard(
                storeID = "mirror/${normalizeMachine(owner)}",
                broker = mirrorBroker,
                machineName = owner,
                brief = item.brief,
                offline = true,
                mirroredAt = item.updated,
            )
        }

        val sortedCards = cards.values.sortedWith(
            compareBy<LabSetCard> { it.brief.set.project }
                .thenByDescending { labCardActivityAt(it) }
                .thenByDescending { it.id },
        )
        val activeByCard = linkedMapOf<String, String>()
        activeKeys.forEach { (record, key) -> cards[record]?.let { activeByCard[it.id] = key.key } }
        val sortedKeys = pendingKeys.values.sortedWith(compareByDescending<LabPendingKey> { it.key.created }.thenByDescending { it.id })
        val sortedRuns = pendingRuns.values.sortedWith(compareByDescending<LabPendingRun> { it.proposal.created }.thenByDescending { it.id })
        val attention = buildList {
            sortedKeys.forEach {
                add(LabAttentionItem(
                    LabAttentionKind.KEY, it.id, "ACCESS", it.key.project, it.machineName,
                    "Approve agent access to a new isolated experiment set.", it.key.created,
                ))
            }
            sortedRuns.forEach {
                add(LabAttentionItem(
                    LabAttentionKind.PROPOSAL, it.id, it.proposal.run, it.proposal.project,
                    it.machineName, it.proposal.intent.ifBlank { "Review this experiment before it starts." },
                    it.proposal.created,
                ))
            }
        }.sortedWith(compareByDescending<LabAttentionItem> { it.created }.thenByDescending { it.id })

        return LabAggregate(
            sortedCards,
            sortedKeys,
            sortedRuns,
            noteGroups.sortedWith(compareBy({ it.machineName.lowercase() }, { it.broker.id })),
            activeByCard,
            attention,
        )
    }

    fun storeKey(broker: Broker, reported: String?): String {
        if (listOf(broker.name, broker.host).any(::isBabelName)) return "shared:babel"
        val clean = reported?.trim().orEmpty()
        return if (clean.isNotEmpty()) "store:$clean" else "machine:${broker.id}"
    }

    private fun isBabelName(raw: String): Boolean {
        val first = raw.lowercase().substringBefore('.')
        return first.startsWith("babel-") || first.startsWith("ut-babel-")
    }

    private fun normalizeMachine(raw: String): String =
        raw.trim().lowercase().substringBefore('.').removePrefix("ut-").removeSuffix(".local")

    private fun machineMatches(broker: Broker, owner: String): Boolean {
        val target = normalizeMachine(owner)
        return listOf(broker.name, broker.host).any { normalizeMachine(it) == target }
    }

    private fun keyRank(status: String) = if (status == "pending") 0 else 1

    private fun prefer(candidate: LabBrief, current: LabBrief): Boolean {
        if (candidate.runs.size != current.runs.size) return candidate.runs.size > current.runs.size
        val candidateLatest = candidate.runs.mapNotNull { it.started }.maxOrNull().orEmpty()
        val currentLatest = current.runs.mapNotNull { it.started }.maxOrNull().orEmpty()
        if (candidateLatest != currentLatest) return candidateLatest > currentLatest
        return candidate.notes.size + candidate.setEvents.size > current.notes.size + current.setEvents.size
    }
}
