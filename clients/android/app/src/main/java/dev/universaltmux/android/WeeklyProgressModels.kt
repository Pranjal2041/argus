package dev.universaltmux.android

import org.json.JSONObject

const val SCREEN_WEEKLY_PROGRESS = 8

data class WeeklyProgressProjectSummary(
    val id: String,
    val name: String,
    val panelCount: Int,
    val workspaceCount: Int,
    val updatedAt: String,
)

data class WeeklyProgressGenerationSummary(
    val id: String,
    val projectId: String,
    val projectName: String,
    val weekStart: String,
    val weekEndExclusive: String,
    val createdAt: String,
    val updatedAt: String,
    val stage: String,
    val state: String,
    val auditPasses: Int,
    val slideCount: Int,
    val hasDeck: Boolean,
    val hasReport: Boolean,
    val evidenceEventCount: Int?,
    val error: String?,
) {
    val isActive get() = state == "active"
    val isComplete get() = state == "complete"
    val canResume get() = state == "interrupted" || state == "failed"
}

data class WeeklyProgressActiveOperation(
    val generationId: String,
    val projectId: String,
    val projectName: String,
    val weekStart: String,
    val stage: String,
    val startedAt: String,
)

data class WeeklyProgressCatalog(
    val generatedAt: String = "",
    val projects: List<WeeklyProgressProjectSummary> = emptyList(),
    val generations: List<WeeklyProgressGenerationSummary> = emptyList(),
    val activeOperation: WeeklyProgressActiveOperation? = null,
) {
    companion object {
        fun parse(raw: String): WeeklyProgressCatalog {
            val root = JSONObject(raw)
            val projectArray = root.optJSONArray("projects")
            val projects = if (projectArray == null) emptyList() else
                (0 until projectArray.length()).map { index ->
                    val value = projectArray.getJSONObject(index)
                    WeeklyProgressProjectSummary(
                        id = value.getString("id"),
                        name = value.getString("name"),
                        panelCount = value.optInt("panelCount"),
                        workspaceCount = value.optInt("workspaceCount"),
                        updatedAt = value.optString("updatedAt"),
                    )
                }
            val generationArray = root.optJSONArray("generations")
            val generations = if (generationArray == null) emptyList() else
                (0 until generationArray.length()).map { index ->
                    val value = generationArray.getJSONObject(index)
                    WeeklyProgressGenerationSummary(
                        id = value.getString("id"),
                        projectId = value.getString("projectID"),
                        projectName = value.getString("projectName"),
                        weekStart = value.getString("weekStart"),
                        weekEndExclusive = value.getString("weekEndExclusive"),
                        createdAt = value.optString("createdAt"),
                        updatedAt = value.optString("updatedAt"),
                        stage = value.optString("stage"),
                        state = value.optString("state"),
                        auditPasses = value.optInt("auditPasses"),
                        slideCount = value.optInt("slideCount"),
                        hasDeck = value.optBoolean("hasDeck"),
                        hasReport = value.optBoolean("hasReport"),
                        evidenceEventCount = if (value.isNull("evidenceEventCount")) null
                            else value.optInt("evidenceEventCount"),
                        error = if (value.isNull("error")) null else value.optString("error").ifBlank { null },
                    )
                }
            val operation = root.optJSONObject("activeOperation")?.let { value ->
                WeeklyProgressActiveOperation(
                    generationId = value.getString("generationID"),
                    projectId = value.getString("projectID"),
                    projectName = value.getString("projectName"),
                    weekStart = value.getString("weekStart"),
                    stage = value.optString("stage"),
                    startedAt = value.optString("startedAt"),
                )
            }
            return WeeklyProgressCatalog(
                generatedAt = root.optString("generatedAt"),
                projects = projects,
                generations = generations,
                activeOperation = operation,
            )
        }
    }
}
