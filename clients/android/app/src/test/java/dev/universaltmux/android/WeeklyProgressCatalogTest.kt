package dev.universaltmux.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WeeklyProgressCatalogTest {
    @Test
    fun parsesProjectsGenerationsAndLiveOperation() {
        val catalog = WeeklyProgressCatalog.parse(
            """
            {
              "version": 1,
              "generatedAt": "2026-08-17T14:00:00Z",
              "projects": [{
                "id": "project-1", "name": "Token-Efficient CUAs",
                "panelCount": 2, "workspaceCount": 1,
                "updatedAt": "2026-08-17T13:00:00Z"
              }],
              "generations": [{
                "id": "generation-1", "projectID": "project-1",
                "projectName": "Token-Efficient CUAs",
                "weekStart": "2026-08-10", "weekEndExclusive": "2026-08-17",
                "createdAt": "2026-08-17T13:00:00Z", "updatedAt": "2026-08-17T14:00:00Z",
                "stage": "auditingSlides", "state": "active", "auditPasses": 2,
                "slideCount": 8, "hasDeck": true, "hasReport": true,
                "evidenceEventCount": 312
              }],
              "activeOperation": {
                "generationID": "generation-1", "projectID": "project-1",
                "projectName": "Token-Efficient CUAs", "weekStart": "2026-08-10",
                "stage": "auditingSlides", "startedAt": "2026-08-17T13:00:00Z"
              }
            }
            """.trimIndent()
        )

        assertEquals("Token-Efficient CUAs", catalog.projects.single().name)
        assertEquals(2, catalog.projects.single().panelCount)
        assertTrue(catalog.generations.single().isActive)
        assertFalse(catalog.generations.single().canResume)
        assertEquals(8, catalog.generations.single().slideCount)
        assertEquals("generation-1", catalog.activeOperation?.generationId)
    }

    @Test
    fun interruptedAndFailedGenerationsCanResumeWithoutOptionalEvidenceFields() {
        val catalog = WeeklyProgressCatalog.parse(
            """
            {
              "projects": [],
              "generations": [
                {
                  "id":"one", "projectID":"p", "projectName":"P",
                  "weekStart":"2026-08-10", "weekEndExclusive":"2026-08-17",
                  "stage":"draftingSlides", "state":"interrupted", "auditPasses":0,
                  "slideCount":0, "hasDeck":false, "hasReport":true
                },
                {
                  "id":"two", "projectID":"p", "projectName":"P",
                  "weekStart":"2026-08-03", "weekEndExclusive":"2026-08-10",
                  "stage":"failed", "state":"failed", "auditPasses":3,
                  "slideCount":4, "hasDeck":false, "hasReport":true,
                  "error":"audit failed"
                }
              ]
            }
            """.trimIndent()
        )

        assertTrue(catalog.generations.all { it.canResume })
        assertEquals(null, catalog.generations.first().evidenceEventCount)
        assertEquals("audit failed", catalog.generations.last().error)
    }
}
